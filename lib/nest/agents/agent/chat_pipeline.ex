defmodule Nest.Agents.Agent.ChatPipeline do
  @moduledoc """
  Chat-handling logic for an agent. Extracted from
  `Nest.Agents.Agent` so the GenServer module stays small.

  Responsibilities:

    * Resolve the effective mode + capabilities for an incoming
      chat turn (falling back to defaults if the requested mode
      is not in the vocation's mode map).
    * Build the user message (persisted and LLM-facing). Both
      carry the same `[mode: <name>]\n` prefix on `content` so
      the mode round-trips through any store / log / replay.
      The chat UI strips the prefix on render.
    * Run the pre-flight check and decide whether to compact
      first or go straight to the ChatTurn.
    * Spawn the ChatTurn via the ChatTurnSupervisor.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Agents.Agent.ChatTurnSpawner
  alias Nest.Agents.Agent.Compaction.Overflow
  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.Part
  alias Nest.Messages.Streaming
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight
  alias Nest.Tokens.Reserve
  alias Nest.Vocations

  @doc """
  Handle an incoming chat turn. Returns the updated state
  tuple for the GenServer to use as its reply.
  """
  @spec handle_chat(Nest.Agents.Agent.t(), String.t(), String.t() | nil) ::
          {:noreply, Nest.Agents.Agent.t()}
  def handle_chat(state, content, requested_mode) do
    # Resolve mode: explicit > agent's current mode > "chat"
    mode = requested_mode || state.live.mode
    # Validate mode against the vocation; fall back to default if invalid.
    {effective_mode, _caps} = resolve_mode_and_caps(mode, state.vocation)

    # Clear the `cancelled` flag from any previous stop so the
    # pre-flight compaction that may run for this turn can
    # actually resume the chat task (the guard in
    # `compaction_done` would otherwise discard the
    # `chat_continuation`).
    state = clear_cancelled(state)

    # Store the user message in `pending_user_message` instead
    # of appending immediately. The pre-flight check uses
    # `messages ++ [pending_user_message_struct]` to decide
    # whether compaction fires. If preflight fits, `handle_chat`
    # consumes the pending field via
    # `append_pending_user_message/1`. If preflight needs
    # compaction, the field stays set across the compaction;
    # the compaction handler's `chat_continuation` branch
    # appends it after compaction succeeds. We store the
    # post-resolution `effective_mode` so the message struct's
    # `[mode: ...]` prefix and `metadata.mode` match what the
    # LLM would see after `resolve_mode_and_caps`.
    state = put_pending_user_message(state, {content, effective_mode})

    state = maybe_compact_then_spawn(state, effective_mode)
    {:noreply, state}
  end

  defp clear_cancelled(state) do
    %{state | live: %{state.live | cancelled: false}}
  end

  # Before appending the user message, check if its projected
  # size (plus current messages) crosses a context-usage threshold.
  # If so, inject a synthetic exchange to maintain wire alternation:
  #
  #   If last wire role is assistant: inject [notice_user, ack_assistant]
  #     → assistant(wire) → user(notice) → assistant(ack) → user(real)  ✓
  #   If last wire role is user: inject a single assistant with the notice
  #     → user(wire) → assistant(notice+ack) → user(real)  ✓
  #
  # When the trailing assistant carries an unpaired `Part.ToolUse{}`
  # (an in-flight tool call waiting for its `tool_result`), the
  # `else` branch would inject between the `tool_use` and the
  # upcoming `tool_result`, breaking Anthropic's tool_use/tool_result
  # pairing invariant. In that case the threshold is marked crossed
  # but the pair is NOT injected here; the ChatTurn's response-
  # construction path (Case 2) handles the notice when the LLM's
  # response is assembled, which is always at a wire-safe boundary.
  defp maybe_inject_context_pair(state) do
    limit = state.llm_metrics.context_limit
    if not is_integer(limit) or limit <= 0, do: state, else: do_check(state, limit)
  end

  defp do_check(state, limit) do
    pending = pending_user_message_struct(state)

    if is_nil(pending) do
      state
    else
      projected = state.chat_state.messages ++ [pending]
      used = ContextReminder.estimate_messages(projected)
      crossed = state.live.crossed_thresholds

      case ContextReminder.highest_unannounced(used, limit, crossed) do
        nil ->
          state

        atom ->
          state = inject_notice(state, atom, crossed)

          %{
            state
            | live: %{state.live | crossed_thresholds: MapSet.put(crossed, atom)}
          }
      end
    end
  end

  defp inject_notice(state, atom, _crossed) do
    notice = ContextReminder.notice_text(atom)
    ack = ContextReminder.ack_text_for(atom)
    spec = %{kind: :context, attention: "Context?", notice: notice, ack: ack}

    case NoticePairInjector.inject_pair_in_process(
           state.chat_state.messages,
           state,
           spec,
           :user_agent
         ) do
      {:ok, _shape, _stamped, new_state} ->
        new_state

      :deferred ->
        # Trailing assistant carries an unpaired tool_use (in-flight
        # tool call). The notice is deferred to the ChatTurn's
        # response-construction path (Case 2), which fires on a
        # wire-safe boundary. `crossed_thresholds` is still updated
        # upstream so the threshold doesn't re-fire on subsequent
        # user messages while the tool call is in flight.
        state
    end
  end

  # Store `{content, mode}` in `state.live.pending_user_message`.
  # The field is the source of truth for the user's incoming
  # message until we know whether compaction fires.
  defp put_pending_user_message(state, pending) do
    %{state | live: %{state.live | pending_user_message: pending}}
  end

  defp clear_pending_user_message(state) do
    %{state | live: %{state.live | pending_user_message: nil}}
  end

  # Build the `Message.t()` struct for the pending user message
  # without appending. Returns `nil` if the field is not set.
  @spec pending_user_message_struct(Nest.Agents.Agent.t()) :: {:user, User.t()} | nil
  def pending_user_message_struct(state) do
    case state.live.pending_user_message do
      nil -> nil
      {content, effective_mode} -> build_user_message(state, content, effective_mode)
    end
  end

  # Append the pending user message via the canonical Agent
  # path so the Agent stamps `index` and the next response's
  # `streaming_acc` is built from the actual stamped index.
  # After appending, the field is cleared.
  defp append_pending_user_message(state) do
    case pending_user_message_struct(state) do
      nil ->
        {nil, state}

      pending_message ->
        {stamped_user, state} = Nest.Agents.Agent.__append_message__(state, pending_message)
        state = clear_pending_user_message(state)
        {stamped_user, state}
    end
  end

  @doc """
  Resume the chat after a compaction completed. Appends the
  pending user message. The compaction handler has already
  replaced the messages list with the compacted state; we
  spawn a ChatTurn via `ChatTurnSpawner.spawn/4` with the
  appended user message.

  If the user clicked Stop while compaction was in flight,
  discard the pending message — the agent's chat task has
  already exited (or is about to) and we don't want to spawn
  a new one.
  """
  @spec resume_with_pending(Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def resume_with_pending(state) do
    state = maybe_inject_context_pair(state)
    {stamped_user, state} = append_pending_user_message(state)

    effective_mode =
      case state.live.pending_user_message do
        nil -> state.live.mode
        {_content, mode} -> mode || state.live.mode
      end

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        state.live.active_message_index
      )

    {_effective_mode, caps} = resolve_mode_and_caps(state.live.mode, state.vocation)
    ChatTurnSpawner.spawn(state, state.chat_state.messages, {:user_message, stamped_user}, caps)
  end

  # Backward-compat alias used by older test fixtures. Routes
  # through `resume_with_pending/1` so the pending message is
  # appended exactly once.
  @deprecated "Use resume_with_pending/1 instead"
  def resume_after_compaction(state, _content, _mode) do
    resume_with_pending(state)
  end

  # Kept for legacy callers (no production path uses this after
  # the post-compaction dispatch consolidated through
  # `ChatTurnSpawner.spawn/4`).

  # Transition the chat_state to `:streaming` after a user message
  # has been appended via `__append_message__/2`. Sets the
  # `active_message_index` (used by the ChatTurn for the request
  # API log) to the user message's actual stamped index, and
  # starts a fresh streaming accumulator for the response at
  # `stamped_index + 1`. Both indices come from the Agent's
  # authoritative `next_message_index`, not from a local
  # prediction.
  defp prepare_streaming_state(state, effective_mode, stamped_index) do
    %{
      state
      | live: %{
          state.live
          | mode: effective_mode,
            status: :streaming,
            active_message_index: stamped_index,
            pending_api_logs: clear_pending_api_logs(state, stamped_index).live.pending_api_logs,
            streaming_acc: Streaming.new(stamped_index + 1),
            tool_index_map: %{}
        }
    }
  end

  # Build the persisted user message. The mode is encoded two ways:
  # on the `metadata.mode` field (used by the UI badge) and as a
  # `[mode: <name>]\n` prefix on the text part itself.
  #
  # The prefix is the source of truth for the LLM: when we
  # re-send prior user messages on the next call (e.g. after
  # compaction rebuilds the message list), the prefix round-trips
  # through whatever store / log / replay we have. The client UI
  # strips the prefix before display because the mode badge already
  # shows it; see `assets/js/utils/stripModePrefix.js`.
  #
  # `index: nil` — the Agent stamps the actual index via
  # `__append_message__/2`. The ChatTurn is no longer the
  # authority on which slot the user message occupies.
  defp build_user_message(state, content, effective_mode) do
    next_idx = state.chat_state.next_message_index

    user = %User{
      index: nil,
      timestamp: DateTime.utc_now(),
      parts: [%Part.Text{text: "[mode: #{effective_mode}]\n#{content}"}],
      metadata: %{"mode" => effective_mode},
      api_logs: get_pending_api_logs(state, next_idx)
    }

    {:user, user}
  end

  # Pre-flight: would the LLM call we'd make next fit in the
  # context window? If not, spawn a compaction task first. The
  # task sends `{:compaction_done, new_messages, continuation}`
  # back; the Agent's `compaction_done` handler then spawns
  # the ChatTurn via `resume_after_compaction/3` with the
  # compacted messages.
  defp maybe_compact_then_spawn(state, effective_mode) do
    # Plan §"In-progress state": compaction is disallowed
    # while streaming. The pre-flight will re-run on the
    # next call (which is the next chat turn, since the
    # in-progress stream is finalizing).
    if streaming_active?(state.live.streaming_acc) do
      append_and_spawn(state, effective_mode)
    else
      handle_preflight(state, effective_mode)
    end
  end

  defp handle_preflight(state, effective_mode) do
    case preflight_decision(messages_with_pending(state), state) do
      decision when decision in [:fits, :no_limit_known] ->
        append_and_spawn(state, effective_mode)

      :needs_compaction ->
        spawn_compaction_pipeline(state)

      :cannot_compact ->
        refuse_compaction(state)
    end
  end

  # The pending user message stays in `pending_user_message`
  # during compaction (so the compactor doesn't try to
  # summarize a brand-new user turn). After compaction
  # succeeds, the compactor's chat turn finishes and
  # `ResultHandler.handle_success/3` resumes via
  # `resume_with_pending/1` with the held user message.
  defp spawn_compaction_pipeline(state) do
    Trigger.post_turn(state)
  end

  # The conversation cannot fit even after compaction would
  # run (system prompt alone exceeds the limit, or the head
  # between system and last user is empty). Refuse the user's
  # request: clear the pending message, set
  # `:context_overflow` status, broadcast a `chat:error` with
  # the actual numbers, and stay idle. The chat channel
  # rejects `chat:message` while the agent is in
  # `:context_overflow` status, so the user can't add more
  # messages until they restart the agent or change the model.
  defp refuse_compaction(state) do
    state = clear_pending_user_message(state)
    state = %{state | live: %{state.live | status: :context_overflow}}

    Broadcasts.status(state)

    system_prompt = render_system_prompt(state)
    reason = refusal_reason(system_prompt, state.llm_metrics.context_limit)

    Overflow.broadcast(
      state,
      "Nest.Agents.Agent.ChatPipeline.handle_preflight/2",
      "start a conversation",
      system_prompt,
      reason
    )

    state
  end

  # Render the current system prompt via the same path the
  # Trigger uses, so the refusal message reports the actual
  # rendered size, not whatever happens to be at
  # `messages[0]` (which can drift).
  defp render_system_prompt(state) do
    {system_prompt, _mode, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(
        state.vocation,
        state.workspace_path,
        {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
        state.name,
        state.depth
      )

    system_prompt
  end

  # Pick the error-message reason: `:system_oversized` when
  # the rendered prompt exceeds the 25% safety budget,
  # `:reserve_exhausted` for everything else (no system, or
  # the headroom-vs-conversation arithmetic failed). Both
  # paths end up in `Overflow.broadcast/5`'s `:reserve_exhausted`
  # default wording except for the oversized case.
  defp refusal_reason(system_prompt, context_limit) do
    if system_prompt != nil and
         not SystemPrompt.within_size_budget?(system_prompt, context_limit) do
      :system_oversized
    else
      :reserve_exhausted
    end
  end

  # The message list for the pre-flight check: existing messages
  # plus the pending user message struct (not yet appended).
  defp messages_with_pending(state) do
    case pending_user_message_struct(state) do
      nil -> state.chat_state.messages
      pending -> state.chat_state.messages ++ [pending]
    end
  end

  # Spawn the chat turn. The user message has already been
  # appended to the Agent (via `append_pending_user_message/1`).
  # `info` is a marker indicating this ChatTurn was spawned from
  # the user-turn-boundary path; the ChatTurn's dispatch is the
  # same as the default flow.
  defp append_and_spawn(state, effective_mode) do
    state = maybe_inject_context_pair(state)
    {stamped_user, state} = append_pending_user_message(state)

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        state.live.active_message_index
      )

    Broadcasts.status(state)
    {_effective_mode, caps} = resolve_mode_and_caps(state.live.mode, state.vocation)
    ChatTurnSpawner.spawn(state, state.chat_state.messages, {:user_message, stamped_user}, caps)
  end

  @doc """
  Public for use by the GenServer's `handle_info({:preflight_request, ...})`.
  Returns one of `:fits`, `:no_limit_known`, or `:needs_compaction`.

  When `state.llm_metrics.context_limit` is `nil` (probe hasn't
  completed or the model isn't in the discovery cache), defers
  to `PreFlight.check_messages/3` with the response-budget floor
  rather than calling `Reserve.response_budget/1` — that function
  has no clause for `nil` and would crash the GenServer. The
  `nil`-limit path returns `:no_limit_known`, which
  `handle_preflight/2` treats the same as `:fits`.
  """
  @spec preflight_decision([{atom(), map()}], Nest.Agents.Agent.t()) :: atom()
  def preflight_decision(messages_for_llm, state) do
    case state.llm_metrics.context_limit do
      limit when is_integer(limit) and limit > 0 ->
        PreFlight.check_messages(
          messages_for_llm,
          limit,
          Reserve.response_budget(limit)
        )

      _ ->
        PreFlight.check_messages(messages_for_llm, nil, Reserve.response_budget_floor())
    end
  end

  @doc """
  Per the plan, compaction is disallowed while streaming. We treat
  "actively streaming" as `streaming_acc` having any accumulated
  text or thinking content. A freshly-initialized accumulator (no
  deltas yet) is NOT considered active — the pre-flight may still
  compact in that brief window before the LLM's first token.
  """
  @spec streaming_active?(term()) :: boolean()
  def streaming_active?(%Streaming.AssistantAccumulator{} = acc) do
    acc.text_buffer != [] or acc.thinking_buffer != []
  end

  def streaming_active?(_), do: false

  # Resolves the effective mode and capability map for a chat message.
  #
  # If `mode` is in the vocation's `modes` map, use it as-is.
  # Otherwise fall back to the vocation's default mode (or "chat" if
  # the vocation has no modes). This matches the LLM-visible
  # `[mode: X]` prefix: we always emit a valid mode to the LLM.
  @doc false
  def resolve_mode_and_caps(mode, %Nest.Vocations.Vocation{} = vocation) do
    modes = Vocations.list_modes(vocation)

    if mode in modes do
      {mode, elem(Vocations.get_caps(vocation, mode), 1)}
    else
      default = Vocations.default_mode(vocation)
      {default, elem(Vocations.get_caps(vocation, default), 1)}
    end
  end

  def resolve_mode_and_caps(_mode, _no_vocation_or_id) do
    # No vocation struct or vocation_id available: only "chat"
    # is valid.
    {"chat", Nest.Sandbox.default_caps()}
  end

  # Read any pending api_logs queued for the given message_index.
  # The pipeline may have been queued before the user message
  # was actually appended; we read them here so the message
  # struct carries the api_logs forward.
  defp get_pending_api_logs(state, message_index) do
    Map.get(state.live.pending_api_logs, message_index, [])
  end

  # Clear the pending api_logs queue for the given message_index
  # after they've been attached to the persisted user message.
  # Returns the new state (with the cleared map) so the caller
  # can chain updates.
  defp clear_pending_api_logs(state, message_index) do
    pending_api_logs =
      Map.delete(state.live.pending_api_logs, message_index)

    %{state | live: %{state.live | pending_api_logs: pending_api_logs}}
  end
end
