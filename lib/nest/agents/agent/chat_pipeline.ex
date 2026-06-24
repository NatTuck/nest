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
      first or go straight to the chat task.
    * Spawn the chat task via the LLMRunner.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.LLMRunner
  alias Nest.Messages.Streaming
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight
  alias Nest.Vocations

  require Logger

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

    {user_message, llm_user_message} = build_user_messages(state, content, effective_mode)

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

    messages_for_llm = state.chat_state.messages ++ [llm_user_message]

    # Pre-flight: does the next LLM call fit? If not, the
    # Compactor runs first (in a Task); the chat task spawns
    # after compaction completes.
    state = maybe_compact_then_chat(state, messages_for_llm, content, mode)

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

    Broadcasts.status(state.id, state)
    spawn_chat_task(state, content, mode)
  end

  @doc """
  Spawn the LLM call chain as a Task under the agent's
  TaskSupervisor. The task is fire-and-forget; it sends
  `:delta_received`, `:llm_usage`, `:tool_calls_received`,
  etc. back to the agent pid as the LLM streams. The task's
  pid is stored on `state.chat_state.chat_task_pid` so the
  stop handler can send it a `{:stop_chat, _}` signal.
  """
  @spec spawn_chat_task(Nest.Agents.Agent.t(), String.t(), String.t()) ::
          Nest.Agents.Agent.t()
  def spawn_chat_task(state, content, mode) do
    agent_pid = self()
    {effective_mode, caps} = resolve_mode_and_caps(mode, state.vocation_id)

    state = broadcast_user_and_prepare_streaming(state, content, effective_mode)
    messages_for_llm = build_llm_messages(state, content, effective_mode)

    ctx = build_run_context(state, agent_pid, caps, messages_for_llm)
    init_state = build_run_state(state)

    chat_task_pid = start_chat_task(agent_pid, ctx, init_state)

    %{state | chat_state: %{state.chat_state | chat_task_pid: chat_task_pid}}
  end

  # Re-broadcast the user message and transition the chat_state to
  # `:streaming` so the LLM-bound version of the user message is
  # visible to the chat task. The user message was already added
  # to `state.chat_state.messages` and broadcast by `handle_chat/3`
  # (or the compaction continuation's resume), so this is a
  # no-op on the message list; we just re-broadcast with the
  # mode-aware context.
  defp broadcast_user_and_prepare_streaming(state, _content, _effective_mode) do
    user_message = List.last(state.chat_state.messages)
    Broadcasts.message(state.id, user_message)

    # handle_chat (or the compaction continuation) has already
    # set state.chat_state.streaming_acc to the correct index. Don't
    # overwrite it here — that would shift the assistant's index
    # by one.
    %{state | chat_state: %{state.chat_state | status: :streaming}}
    |> tap(&Broadcasts.status(&1.id, &1))
  end

  # Build the message list passed to the LLM. The last message is
  # the user message with the mode prefix prepended; the rest are
  # the prior history (everything except the user message we just
  # added).
  defp build_llm_messages(state, content, effective_mode) do
    user_message = List.last(state.chat_state.messages)
    llm_user_message = llm_user_message(user_message, content, effective_mode)
    Enum.drop(state.chat_state.messages, -1) ++ [llm_user_message]
  end

  # Transition the chat_state to `:streaming` after a user message
  # has been appended via `__append_message__/2`. Sets the
  # `active_message_index` (used by the LLMRunner for the request
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

  defp build_run_context(state, agent_pid, caps, messages_for_llm) do
    %LLMRunner.RunContext{
      client_config: state.client_config,
      tools: state.tools,
      messages: messages_for_llm,
      agent_pid: agent_pid,
      agent_id: state.id,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source
    }
  end

  defp build_run_state(state) do
    %LLMRunner.RunState{
      message_index: state.chat_state.streaming_acc.index,
      active_message_index: state.chat_state.active_message_index,
      api_log_sequences: state.chat_state.api_log_sequences,
      max_iterations: Nest.Agents.Agent.configured_max_tool_iterations()
    }
  end

  # Spawn the chat task under the application-wide
  # `Task.Supervisor`. If the supervisor is saturated, fall
  # back to a no-pid state (the stop handler treats `nil` as a
  # no-op).
  defp start_chat_task(agent_pid, ctx, init_state) do
    case Task.Supervisor.start_child(
           Nest.Agents.TaskSupervisor,
           fn -> run_chat_task_and_notify(agent_pid, ctx, init_state) end
         ) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  # Body of the spawned chat task. Wraps `LLMRunner.run/2` in a
  # try/catch so we can distinguish three exit paths:
  #
  #   * User-initiated stop — `:exit` (the inner receives returned
  #     `:stopped`) or `ToolLoop.StoppedError` (raised by the
  #     tool executor when the agent sent a `{:stop_chat, _}`).
  #     We send `{:chat_stopped, self()}` so the agent can
  #     finalize the partial accumulator and transition to idle.
  #
  #   * Normal completion — `LLMRunner.run/2` returned. We send
  #     `{:api_log_sequences_updated, _}` as the standard ack.
  #
  #   * Unexpected crash — any other `:error` (e.g. a
  #     `FunctionClauseError` from an LLM client that received
  #     an unrecognized delta shape). We send
  #     `{:chat_task_crashed, msg}` so the agent can finalize
  #     the partial, broadcast a `chat:error` to the UI, and
  #     transition to idle. The task exits `:normal` either way
  #     so the supervisor doesn't see a crash and the agent's
  #     `ExitHandler` doesn't trip.
  #
  # The chat task is started under the application-wide
  # `Task.Supervisor` (see `start_chat_task/3`) which monitors —
  # not links — the task, so the agent has no other way to
  # discover a crash. This catch is the agent's only signal.
  #
  # On `:error` we forward the FULL exception + stacktrace to
  # the GenServer (so the server log has the file/line of the
  # crash and the UI can show a useful snippet). Using
  # `Exception.message/1` alone hides the call site — see
  # AGENTS.md-style notes above `chat_task_crashed/2` in
  # `LLMStreamHandler` for the receiver contract.
  defp run_chat_task_and_notify(agent_pid, ctx, init_state) do
    LLMRunner.run(ctx, init_state)
    send(agent_pid, {:api_log_sequences_updated, init_state})
  catch
    :exit, _ ->
      send(agent_pid, {:chat_stopped, self()})

    :error, %Nest.Agents.Agent.ToolLoop.StoppedError{} ->
      send(agent_pid, {:chat_stopped, self()})

    :error, exception ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        formatted = Exception.format(:error, exception, stacktrace)

        "[agent_chat_task] CRASHED:\n" <>
          ("agent_id=" <>
             ctx.agent_id <> " message_index=" <> inspect(init_state.message_index) <> "\n") <>
          formatted
      end)

      send(agent_pid, {:chat_task_crashed, exception, stacktrace})
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
  # `__append_message__/2`. The LLMRunner is no longer the
  # authority on which slot the user message occupies.
  defp build_user_messages(state, content, effective_mode) do
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

  # Build a fresh user message struct. Mirrors the user-message
  # construction in handle_chat/3 so callers (the compaction
  # continuation flow) build the same shape. Includes the
  # `[mode: <name>]\n` prefix on `content` for the same reason as
  # `build_user_messages/3` (the LLM sees the prefix and the UI
  # strips it).
  defp build_user_message(state, content, effective_mode) do
    {:user,
     %User{
       index: nil,
       timestamp: DateTime.utc_now(),
       content: "[mode: #{effective_mode}]\n#{content}",
       metadata: %{"mode" => effective_mode},
       api_logs: get_pending_api_logs(state, state.chat_state.next_message_index)
     }}
  end

  # The persisted user message is already prefixed with the
  # effective mode (see `build_user_messages/3`), so the LLM-facing
  # version is the same struct. Kept as a separate function so the
  # call site reads symmetrically with `build_user_messages/3` and
  # so a future split (e.g. an LLM-only payload format) can be
  # reintroduced without rewiring callers.
  defp llm_user_message(user_message, _content, _effective_mode) do
    user_message
  end

  # Pre-flight: would the LLM call we'd make next fit in the
  # context window? If not, spawn a compaction task first. The
  # task sends `{:compaction_done, new_messages, continuation}`
  # back; we then spawn the original chat task with the new
  # messages.
  defp maybe_compact_then_chat(state, messages_for_llm, content, mode) do
    # Plan §"In-progress state": compaction is disallowed while
    # streaming. The pre-flight will re-run on the next call
    # (which is the next chat turn, since the in-progress
    # stream is finalizing).
    if streaming_active?(state.chat_state.streaming_acc) do
      spawn_chat_task(state, content, mode)
    else
      case preflight_decision(messages_for_llm, state) do
        decision when decision in [:fits, :no_limit_known] ->
          spawn_chat_task(state, content, mode)

        :needs_compaction ->
          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            messages_for_llm,
            {:chat_continuation, {content, mode}}
          )
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
