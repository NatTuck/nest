defmodule Nest.Agents.Agent.Handlers.CompactionHandler do
  @moduledoc """
  `handle_info/2` handlers for compaction-related events:
  `{:compaction_done, _, _}`, `{:compact_context_from_task, _, _}`,
  `{:compact_context_done, _, _}`, `{:preflight_request, _, _}`,
  `{:compaction_failed_for_preflight, _, _}`,
  `{:compact_context_failed, _, _}`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  require Logger

  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction

  @doc """
  Dispatch a compaction message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, new_messages, continuation}, state) do
    compaction_done(new_messages, continuation, state)
  end

  def handle({:compact_context_from_task, task_pid, focus}, state) do
    compact_context_from_task(task_pid, focus, state)
  end

  def handle({:compact_context_done, task_pid, new_messages}, state) do
    compact_context_done(task_pid, new_messages, state)
  end

  def handle({:preflight_request, task_pid, messages_for_llm}, state) do
    preflight_request(task_pid, messages_for_llm, state)
  end

  def handle({:compaction_failed_for_preflight, task_pid, reason}, state) do
    compaction_failed_for_preflight(task_pid, reason, state)
  end

  def handle({:compact_context_failed, task_pid, reason}, state) do
    compact_context_failed(task_pid, reason, state)
  end

  defp compaction_done(new_messages, continuation, state) do
    Logger.info(
      "Compaction complete: agent=#{state.id} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    # Archive the previous messages to history with a marker,
    # then replace state.chat_state.messages with the compacted state.
    state = archive_and_compact(state, new_messages)

    case continuation do
      {:chat_continuation, {content, mode}} ->
        state = ChatPipeline.resume_after_compaction(state, content, mode)
        {:noreply, state}

      {:preflight_continuation, task_pid} ->
        # The chat task that requested this pre-flight was sitting
        # in a `receive` waiting for the result. Send it the new
        # compacted message list so it can resume the LLM call.
        send(task_pid, {:preflight_result, :compacted, new_messages})
        {:noreply, state}

      {:compact_context_continuation, task_pid} ->
        # The chat task invoked the `compact_context` tool and is
        # blocked on a receive for the result. Send it the new
        # messages so it can construct the tool result string.
        send(task_pid, {:compact_context_done, new_messages})
        {:noreply, state}
    end
  end

  defp compact_context_from_task(task_pid, _focus, state) do
    # The chat task is mid-flow and asked for explicit
    # compaction. Spawn the compactor and send the result back
    # to the task when done. The task will unblock its receive
    # and use the result.
    Compaction.spawn(
      self(),
      state.client_config,
      state.llm_metrics.context_limit,
      state.chat_state.messages || [],
      {:compact_context_continuation, task_pid}
    )

    {:noreply, state}
  end

  defp compact_context_done(task_pid, new_messages, state) do
    # Forward to a special handle_info that doesn't also run
    # the chat continuation. We mutate state directly here
    # and send the result back to the task.
    Logger.info(
      "compact_context tool: agent=#{state.id} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    state = archive_and_compact(state, new_messages)
    send(task_pid, {:compact_context_done, new_messages})
    {:noreply, state}
  end

  defp preflight_request(task_pid, _messages_for_llm, state) do
    # Called from the chat task right before each recursive LLM
    # call (after a tool iteration). Runs the pre-flight check
    # against the agent's *current* state.chat_state.messages (the source
    # of truth, since the task's snapshot may be stale by now).
    # If compaction is needed, spawns a compactor and the task
    # waits for the result; otherwise replies `:proceed` and the
    # task uses its current snapshot unchanged.
    if ChatPipeline.streaming_active?(state.chat_state.streaming_acc) do
      send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
      {:noreply, state}
    else
      case ChatPipeline.preflight_decision(state.chat_state.messages || [], state) do
        decision when decision in [:fits, :no_limit_known] ->
          send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
          {:noreply, state}

        :needs_compaction ->
          Compaction.spawn(
            self(),
            state.client_config,
            state.llm_metrics.context_limit,
            state.chat_state.messages || [],
            {:preflight_continuation, task_pid}
          )

          {:noreply, state}
      end
    end
  end

  defp compaction_failed_for_preflight(task_pid, _reason, state) do
    # Compactor raised (LLM error, etc.). The chat task is
    # blocked waiting for a result; let it proceed with its
    # existing snapshot rather than deadlock the agent.
    send(task_pid, {:preflight_result, :proceed, state.chat_state.messages || []})
    {:noreply, state}
  end

  defp compact_context_failed(task_pid, reason, state) do
    Logger.warning("compact_context tool failed: #{inspect(reason)}")
    send(task_pid, {:compact_context_failed, reason})
    {:noreply, state}
  end

  # `archive_and_compact` lives in the GenServer module because
  # it mutates chat history; we forward to it from here.
  defp archive_and_compact(state, new_messages) do
    Nest.Agents.Agent.__archive_and_compact__(state, new_messages)
  end
end
