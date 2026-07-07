defmodule Nest.Agents.Agent.ChatTurn.Iteration do
  @moduledoc """
  Per-iteration helpers for the ChatTurn's `safe_iterate/1`
  step. Extracted from `Nest.Agents.Agent.ChatTurn` to keep
  the iteration state machine under the credo complexity
  and line limits.

  The ChatTurn's iteration step has three concerns beyond
  the basic state-machine work:

    * broadcasting the "max iterations reached" notification
      when the cap is hit (so the UI can show a banner);
    * short-circuiting when the user clicked Stop during
      the previous iteration (the Agent's `cancelled` flag
      is checked via `:get_messages_with_cancelled`);
    * dispatching the LLM call — inject a context warning
      if appropriate, then spawn the HTTP worker.

  Each public helper returns either `:ok` or the GenServer
  reply tuple (`{:noreply, state}` / `{:stop, :normal, state}`)
  so the ChatTurn's `safe_iterate/1` can chain them or
  return them directly.

  ## Why no preflight here?

  The previous design ran a per-iteration preflight (Trigger A
  in `notes/extract-compaction-and-resumable-chat-turn.md`)
  that asked the Agent to compact if the message list would
  exceed `context_limit`. That has been replaced by the
  three-phase `Nest.Agents.Agent.BatchSizer`:

    * Batch preflight runs *after* tools execute, against
      their actual sizes.
    * Mid-sequence compaction is forbidden: the chat task's
      iteration loop is purely mechanical.
    * Compaction fires only at user-turn boundaries
      (`ChatPipeline.handle_chat/3`) or via LLM-driven
      `context.compact` calls.

  The "never send an LLM request whose message list
  predictably overflows" constraint is now satisfied by the
  BatchSizer's preflight + keep-or-summarize decision; this
  module just spawns the HTTP worker with the latest
  `state.chat_state.messages`.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Agents.Agent.ChatTurn.HTTPWorker
  alias Nest.Agents.Agent.ChatTurn.State

  @doc """
  Broadcast a `chat_notification` so the UI can show a
  banner ("Max tool iterations reached") when this
  iteration crosses the cap. Returns `:ok`.
  """
  @spec notify_max_iterations(State.t()) :: :ok
  def notify_max_iterations(state) do
    if state.iteration > state.max_iterations do
      Broadcasts.notification(state.ctx.agent_name, %{
        type: "max_iterations",
        message: "Max tool iterations reached"
      })
    end

    :ok
  end

  @doc """
  The user clicked Stop. Notify the Agent and stop the
  ChatTurn. The Agent's `chat_stopped` handler does the
  actual finalization (it has the current `streaming_acc`
  accumulator). Returns `{:stop, :normal, state}`.
  """
  @spec finalize_cancelled(State.t()) :: {:stop, :normal, State.t()}
  def finalize_cancelled(state) do
    send(state.ctx.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  @doc """
  Spawn the HTTP worker with the current `messages` list.
  Injects a context warning if a new threshold was crossed
  before doing so.

  No preflight or compaction is triggered from this step.
  Compaction can only fire at user-turn boundaries or via
  the `context.compact` tool action; both are owned by the
  Agent, not the chat task's iteration loop.

  Returns the GenServer reply tuple.
  """
  @spec dispatch_batch(State.t(), list()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def dispatch_batch(state, messages) do
    state = inject_context_warning(state, messages)
    spawn_http_worker(state, messages)
  end

  # If the current messages cross a context-usage
  # threshold that hasn't been announced yet, append a
  # `{:system, _}` reminder. See
  # `Nest.Agents.Agent.ChatTurn.ContextReminder` for the
  # firing rules. Skipped when `ctx.context_limit` is nil
  # (probe hasn't completed).
  defp inject_context_warning(state, messages) do
    limit = state.ctx.context_limit

    with limit when is_integer(limit) and limit > 0 <- limit,
         used = ContextReminder.estimate_messages(messages),
         atom when not is_nil(atom) <-
           ContextReminder.highest_unannounced(used, limit, state.crossed_thresholds) do
      msg = ContextReminder.build_message(atom, used, limit)
      _stamped = GenServer.call(state.ctx.agent_pid, {:append_message, msg})
      %{state | crossed_thresholds: MapSet.put(state.crossed_thresholds, atom)}
    else
      _ -> state
    end
  end

  # Spawn the HTTP worker as a Task under
  # `Nest.Agents.TaskSupervisor`. The worker calls
  # `Nest.LLM.Runner.request/2` with the given `messages`
  # and sends `{:http_response, response}` or
  # `{:http_error, error}` back to the ChatTurn.
  #
  # When we've hit the iteration cap, the next call is
  # the "final" call: `tools: nil, tool_choice: :none` so
  # the LLM sees the tool results and produces a text
  # response. The MockClient honors `tools: nil` by
  # skipping any queued tool responses and returning the
  # next text response.
  defp spawn_http_worker(state, messages) do
    parent = self()
    agent_pid = state.ctx.agent_pid

    # The request log is queued at the last message's
    # index (the message that triggered this LLM call:
    # the user message on a fresh turn, the tool message
    # on a continuation). The Agent's `api_log_handler`
    # will re-broadcast that message with the request log
    # attached (the message already exists in the
    # messages list, so the append-to-existing-message
    # path fires).
    request_log_index = last_message_index_for_request_log(messages)
    :ok = APILog.request(state, request_log_index, messages)

    {tools, tool_choice} =
      if state.iteration > state.max_iterations,
        do: {nil, :none},
        else: {state.ctx.tools, state.ctx.tool_choice}

    state = %{state | ctx: %{state.ctx | tools: tools, tool_choice: tool_choice}}

    task =
      Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn -> HTTPWorker.run(state, parent, messages) end
      )

    case task do
      {:ok, pid} ->
        Process.monitor(pid)
        {:noreply, %{state | active_worker: pid, active_worker_kind: :http}}

      _ ->
        # Saturated supervisor. Send a crash to the Agent
        # and stop cleanly.
        send(agent_pid, {:chat_crashed, :saturated, []})
        {:stop, :normal, state}
    end
  end

  # Return the index of the last message in the messages
  # list. The request api_log is queued at this index so
  # the message that triggered this LLM call (the user
  # message on a fresh turn, the tool message on a
  # continuation) is re-broadcast with the request log
  # attached.
  defp last_message_index_for_request_log([]), do: 0

  defp last_message_index_for_request_log(messages) do
    case List.last(messages) do
      nil -> 0
      {_, %{index: idx}} -> idx
      _ -> 0
    end
  end
end
