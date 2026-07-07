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
  alias Nest.Agents.Agent.ChatTurnSupervisor
  alias Nest.Agents.Agent.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.Streaming
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight
  alias Nest.Vocations

  @preflight_reserve 8_192

  @doc """
  Handle an incoming chat turn. Returns the updated state
  tuple for the GenServer to use as its reply.
  """
  @spec handle_chat(Nest.Agents.Agent.t(), String.t(), String.t() | nil) ::
          {:noreply, Nest.Agents.Agent.t()}
  def handle_chat(state, content, requested_mode) do
    # Resolve mode: explicit > agent's current mode > "chat"
    mode = requested_mode || state.mode
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
    %{state | chat_state: %{state.chat_state | cancelled: false}}
  end

  # Store `{content, mode}` in `state.chat_state.pending_user_message`.
  # The field is the source of truth for the user's incoming
  # message until we know whether compaction fires.
  defp put_pending_user_message(state, pending) do
    %{state | chat_state: %{state.chat_state | pending_user_message: pending}}
  end

  defp clear_pending_user_message(state) do
    %{state | chat_state: %{state.chat_state | pending_user_message: nil}}
  end

  # Build the `Message.t()` struct for the pending user message
  # without appending. Returns `nil` if the field is not set.
  @spec pending_user_message_struct(Nest.Agents.Agent.t()) :: {:user, User.t()} | nil
  defp pending_user_message_struct(state) do
    case state.chat_state.pending_user_message do
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
  pending user message, prepares the streaming state, and
  spawns the chat turn. Called from the compaction handler's
  `chat_continuation` branch.
  """
  @spec resume_with_pending(Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def resume_with_pending(state) do
    {_stamped_user, state} = append_pending_user_message(state)

    effective_mode =
      case state.chat_state.pending_user_message do
        # After `append_pending_user_message/1`, the field is cleared;
        # fall back to the agent's current mode.
        nil -> state.mode
        # Defensive: if the field is somehow still set, use its mode.
        {_content, mode} -> mode || state.mode
      end

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        state.chat_state.active_message_index
      )

    spawn_chat_turn(state)
  end

  # Backward-compat alias used by older test fixtures. Routes
  # through `resume_with_pending/1` so the pending message is
  # appended exactly once.
  @deprecated "Use resume_with_pending/1 instead"
  def resume_after_compaction(state, _content, _mode) do
    resume_with_pending(state)
  end

  @doc """
  Spawn a ChatTurn child under the ChatTurnSupervisor.
  The ChatTurn drives the iteration by calling
  `Nest.LLM.Runner.request/2` directly. Its pid is
  stored on `state.chat_state.chat_turn_pid` so the
  stop handler can send it a `{:stop_chat, _}` signal.

  If the supervisor is saturated (a previous ChatTurn
  hasn't been cleaned up yet), fall back to a no-pid
  state. The stop handler treats `nil` as a no-op, and
  the next chat turn will retry.
  """
  @spec spawn_chat_turn(Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def spawn_chat_turn(state) do
    {_effective_mode, caps} = resolve_mode_and_caps(state.mode, state.vocation)
    agent_pid = self()

    ctx = %{
      agent_pid: agent_pid,
      agent_name: state.name,
      client_config: state.client_config,
      tools: state.tools,
      tool_choice: :auto,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      messages: state.chat_state.messages,
      tmp_path: state.tmp_path
    }

    case ChatTurnSupervisor.start_chat_turn(agent_pid, ctx) do
      {:ok, chat_turn_pid} ->
        %{state | chat_state: %{state.chat_state | chat_turn_pid: chat_turn_pid}}

      _ ->
        %{state | chat_state: %{state.chat_state | chat_turn_pid: nil}}
    end
  end

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
      | mode: effective_mode,
        chat_state: %{
          state.chat_state
          | status: :streaming,
            active_message_index: stamped_index,
            pending_api_logs:
              clear_pending_api_logs(state, stamped_index).chat_state.pending_api_logs,
            streaming_acc: Streaming.new(stamped_index + 1)
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
    if streaming_active?(state.chat_state.streaming_acc) do
      append_and_spawn(state, effective_mode)
    else
      case preflight_decision(messages_with_pending(state), state) do
        decision when decision in [:fits, :no_limit_known] ->
          append_and_spawn(state, effective_mode)

        :needs_compaction ->
          state = %{state | chat_state: %{state.chat_state | status: :compacting}}
          Broadcasts.status(state.name, state)

          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            state.chat_state.messages,
            {:chat_continuation, :pending}
          )

          state
      end
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

  # Append the pending user message, prepare the streaming
  # state, and spawn the chat turn. Used on the no-compaction
  # path.
  defp append_and_spawn(state, effective_mode) do
    {{:user, _user}, state} = append_pending_user_message(state)

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        state.chat_state.active_message_index
      )

    Broadcasts.status(state.name, state)
    spawn_chat_turn(state)
  end

  @doc """
  Public for use by the GenServer's `handle_info({:preflight_request, ...})`.
  Returns one of `:fits`, `:no_limit_known`, or `:needs_compaction`.
  """
  @spec preflight_decision([{atom(), map()}], Nest.Agents.Agent.t()) :: atom()
  def preflight_decision(messages_for_llm, state) do
    PreFlight.check_messages(
      messages_for_llm,
      state.llm_metrics.context_limit,
      @preflight_reserve
    )
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
  defp resolve_mode_and_caps(mode, %Nest.Vocations.Vocation{} = vocation) do
    modes = Vocations.list_modes(vocation)

    if mode in modes do
      {mode, elem(Vocations.get_caps(vocation, mode), 1)}
    else
      default = Vocations.default_mode(vocation)
      {default, elem(Vocations.get_caps(vocation, default), 1)}
    end
  end

  defp resolve_mode_and_caps(_mode, _no_vocation_or_id) do
    # No vocation struct or vocation_id available: only "chat"
    # is valid.
    {"chat", Nest.Sandbox.default_caps()}
  end

  # Read any pending api_logs queued for the given message_index.
  # The pipeline may have been queued before the user message
  # was actually appended; we read them here so the message
  # struct carries the api_logs forward.
  defp get_pending_api_logs(state, message_index) do
    Map.get(state.chat_state.pending_api_logs, message_index, [])
  end

  # Clear the pending api_logs queue for the given message_index
  # after they've been attached to the persisted user message.
  # Returns the new state (with the cleared map) so the caller
  # can chain updates.
  defp clear_pending_api_logs(state, message_index) do
    pending_api_logs =
      Map.delete(state.chat_state.pending_api_logs, message_index)

    %{state | chat_state: %{state.chat_state | pending_api_logs: pending_api_logs}}
  end
end
