defmodule Nest.Agents.Agent.ChatPipeline do
  @moduledoc """
  Chat-handling logic for an agent. Extracted from
  `Nest.Agents.Agent` so the GenServer module stays small.

  Responsibilities:

    * Resolve the effective mode + capabilities for an incoming
      chat turn (falling back to defaults if the requested mode
      is not in the vocation's mode map).
    * Build the user message (persisted and LLM-facing).
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

    messages = state.chat_state.messages ++ [user_message]
    messages_for_llm = state.chat_state.messages ++ [llm_user_message]

    # Broadcast user message to all subscribers
    Broadcasts.message(state.id, user_message)

    state = apply_user_message_to_state(state, messages, effective_mode)
    Broadcasts.status(state.id, :streaming)

    # Pre-flight: does the next LLM call fit? If not, the
    # Compactor runs first (in a Task); the chat task spawns
    # after compaction completes.
    state = maybe_compact_then_chat(state, messages_for_llm, content, mode)

    {:noreply, state}
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
    Broadcasts.message(state.id, user_message)

    state = %{
      state
      | messages: state.chat_state.messages ++ [user_message],
        next_message_index: state.chat_state.next_message_index + 1,
        status: :streaming,
        active_message_index: state.chat_state.next_message_index,
        pending_api_logs:
          clear_pending_api_logs(state, state.chat_state.next_message_index).chat_state.pending_api_logs,
        streaming_acc: Streaming.new(state.chat_state.next_message_index + 1)
    }

    Broadcasts.status(state.id, :streaming)
    spawn_chat_task(state, content, mode)
  end

  @doc """
  Spawn the LLM call chain as a Task under the agent's
  TaskSupervisor. The task is fire-and-forget; it sends
  `:delta_received`, `:llm_usage`, `:tool_calls_received`,
  etc. back to the agent pid as the LLM streams.
  """
  @spec spawn_chat_task(Nest.Agents.Agent.t(), String.t(), String.t()) ::
          Nest.Agents.Agent.t()
  def spawn_chat_task(state, content, mode) do
    agent_pid = self()
    {effective_mode, caps} = resolve_mode_and_caps(mode, state.vocation_id)

    # handle_chat has already added the user message to state.chat_state.messages
    # and broadcast it. The last message in state.chat_state.messages is our
    # user message; we just need to construct the LLM-bound version
    # with the mode prefix.
    user_message = List.last(state.chat_state.messages)
    llm_user_message = llm_user_message(user_message, content, effective_mode)
    messages_for_llm = Enum.drop(state.chat_state.messages, -1) ++ [llm_user_message]

    Broadcasts.message(state.id, user_message)

    # handle_chat (or the compaction continuation) has already
    # set state.chat_state.streaming_acc to the correct index. Don't
    # overwrite it here — that would shift the assistant's index
    # by one.
    state = %{state | chat_state: %{state.chat_state | status: :streaming}}
    Broadcasts.status(state.id, :streaming)

    ctx = %LLMRunner.RunContext{
      client_config: state.client_config,
      tools: state.tools,
      system_prompt: state.system_prompt,
      messages: messages_for_llm,
      agent_pid: agent_pid,
      agent_id: state.id,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source
    }

    init_state = %LLMRunner.RunState{
      message_index: state.chat_state.streaming_acc.index,
      active_message_index: state.chat_state.active_message_index,
      api_log_sequences: state.chat_state.api_log_sequences,
      max_iterations: Nest.Agents.Agent.configured_max_tool_iterations()
    }

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      %LLMRunner.RunState{api_log_sequences: updated_sequences} =
        LLMRunner.run(ctx, init_state)

      send(agent_pid, {:api_log_sequences_updated, updated_sequences})
    end)

    state
  end

  # Build the persisted user message (raw content + metadata.mode)
  # and the LLM-facing user message (with the mode prefixed into
  # the content). The persisted form is what gets broadcast and
  # saved; the LLM form is what the model sees on the next call.
  defp build_user_messages(state, content, effective_mode) do
    next_idx = state.chat_state.next_message_index
    user = %User{
      index: next_idx,
      timestamp: DateTime.utc_now(),
      content: content,
      metadata: %{"mode" => effective_mode},
      api_logs: get_pending_api_logs(state, next_idx)
    }

    llm_content = "[mode: #{effective_mode}]\n#{content}"
    user_message = {:user, user}
    llm_user_message = {:user, %{user | content: llm_content}}
    {user_message, llm_user_message}
  end

  # Build a fresh user message struct. Mirrors the user-message
  # construction in handle_chat/3 so callers (the compaction
  # continuation flow) build the same shape.
  defp build_user_message(state, content, effective_mode) do
    {:user,
     %User{
       index: state.chat_state.next_message_index,
       timestamp: DateTime.utc_now(),
       content: content,
       metadata: %{"mode" => effective_mode},
       api_logs: get_pending_api_logs(state, state.chat_state.next_message_index)
     }}
  end

  defp llm_user_message(user_message, content, effective_mode) do
    llm_content = "[mode: #{effective_mode}]\n#{content}"
    {:user, %{elem(user_message, 1) | content: llm_content}}
  end

  # Mutate the chat_state to reflect the new user message:
  # append to history, advance the index, mark streaming,
  # reset pending API logs, and start a fresh streaming acc.
  defp apply_user_message_to_state(state, messages, _effective_mode) do
    next_idx = state.chat_state.next_message_index

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            next_message_index: next_idx + 1,
            status: :streaming,
            active_message_index: next_idx,
            pending_api_logs:
              clear_pending_api_logs(state, next_idx).chat_state.pending_api_logs,
            streaming_acc: Streaming.new(next_idx + 1)
        }
    }
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
    PreFlight.check_messages(messages_for_llm, state.llm_metrics.context_limit, @preflight_reserve)
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
