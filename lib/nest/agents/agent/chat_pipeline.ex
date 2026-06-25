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
    {effective_mode, _caps} = resolve_mode_and_caps(mode, state.vocation_id)

    {user_message, llm_user_message} = build_user_message(state, content, effective_mode)

    # Clear the `cancelled` flag from any previous stop so the
    # pre-flight compaction that may run for this turn can
    # actually resume the chat task (the guard in
    # `compaction_done` would otherwise discard the
    # `chat_continuation`).
    state = clear_cancelled(state)

    # Append the user message via the canonical Agent path so
    # the Agent stamps `index` and the next response's
    # `streaming_acc` is built from the actual stamped index
    # (no more `next_idx + 1` prediction that could drift from
    # `next_message_index` if a side-channel message were
    # appended first). The broadcast happens inside
    # `__append_message__/2`.
    {stamped_user, state} = Nest.Agents.Agent.__append_message__(state, user_message)

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        Nest.Agents.Agent.stamped_index(stamped_user)
      )

    Broadcasts.status(state.id, state)

    state = maybe_compact_then_spawn(state, [llm_user_message], content, mode)
    {:noreply, state}
  end

  defp clear_cancelled(state) do
    %{state | chat_state: %{state.chat_state | cancelled: false}}
  end

  @doc """
  Resume the chat after a compaction completed. Mirrors
  `handle_chat/3`'s user-message + state-transition logic, but
  skips the pre-flight (we just compacted).
  """
  @spec resume_after_compaction(Nest.Agents.Agent.t(), String.t(), String.t()) ::
          Nest.Agents.Agent.t()
  def resume_after_compaction(state, content, mode) do
    {effective_mode, _} = resolve_mode_and_caps(mode, state.vocation_id)
    user_message = build_user_message(state, content, effective_mode)

    {stamped_user, state} = Nest.Agents.Agent.__append_message__(state, user_message)

    state =
      prepare_streaming_state(
        state,
        effective_mode,
        Nest.Agents.Agent.stamped_index(stamped_user)
      )

    spawn_chat_turn(state)
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
    {_effective_mode, caps} = resolve_mode_and_caps(state.mode, state.vocation_id)
    agent_pid = self()

    ctx = %{
      agent_pid: agent_pid,
      agent_id: state.id,
      client_config: state.client_config,
      tools: state.tools,
      tool_choice: :auto,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      messages: state.chat_state.messages
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
  # `[mode: <name>]\n` prefix on the `content` field itself.
  #
  # The prefix on `content` is the source of truth for the LLM:
  # when we re-send prior user messages on the next call (e.g. after
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
      content: "[mode: #{effective_mode}]\n#{content}",
      metadata: %{"mode" => effective_mode},
      api_logs: get_pending_api_logs(state, next_idx)
    }

    user_message = {:user, user}
    llm_user_message = user_message
    {user_message, llm_user_message}
  end

  # Pre-flight: would the LLM call we'd make next fit in the
  # context window? If not, spawn a compaction task first. The
  # task sends `{:compaction_done, new_messages, continuation}`
  # back; the Agent's `compaction_done` handler then spawns
  # the ChatTurn via `resume_after_compaction/3` with the
  # compacted messages.
  defp maybe_compact_then_spawn(state, _messages_for_llm, content, mode) do
    # Plan §"In-progress state": compaction is disallowed
    # while streaming. The pre-flight will re-run on the
    # next call (which is the next chat turn, since the
    # in-progress stream is finalizing).
    if streaming_active?(state.chat_state.streaming_acc) do
      spawn_chat_turn(state)
    else
      case preflight_decision(state.chat_state.messages, state) do
        decision when decision in [:fits, :no_limit_known] ->
          spawn_chat_turn(state)

        :needs_compaction ->
          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            state.chat_state.messages,
            {:chat_continuation, {content, mode}}
          )

          state
      end
    end
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
    acc.text_buffer != "" or acc.thinking_buffer != ""
  end

  def streaming_active?(_), do: false

  # Resolves the effective mode and capability map for a chat message.
  #
  # If `mode` is in the vocation's `modes` map, use it as-is.
  # Otherwise fall back to the vocation's default mode (or "chat" if
  # the vocation has no modes). This matches the LLM-visible
  # `[mode: X]` prefix: we always emit a valid mode to the LLM.
  defp resolve_mode_and_caps(mode, vocation_id) do
    case if(vocation_id, do: Vocations.get_vocation(vocation_id), else: nil) do
      nil ->
        # No vocation: only "chat" is valid.
        {"chat", Nest.Sandbox.default_caps()}

      vocation ->
        modes = Vocations.list_modes(vocation)

        if mode in modes do
          {mode, elem(Vocations.get_caps(vocation, mode), 1)}
        else
          default = Vocations.default_mode(vocation)
          {default, elem(Vocations.get_caps(vocation, default), 1)}
        end
    end
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
