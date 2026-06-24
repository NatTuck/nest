defmodule Nest.Agents.Agent.Handlers.StopHandler do
  @moduledoc """
  `handle_info/2` handlers for the user-initiated chat stop flow:

    * `{:stop_chat, from}` — the channel pushed a `chat:stop` to
      the GenServer. The handler signals the in-flight chat
      task (if any) to halt at its next blocking receive, sets
      the `cancelled` flag (so the in-flight compaction
      `chat_continuation` does not auto-resume a new chat
      turn), and replies to the channel push.
    * `{:chat_stopped, task_pid}` — the chat task has finished
      unwinding in response to the stop signal. The handler
      finalizes the partial `Streaming.AssistantAccumulator`
      into a `%Assistant{...}` message (tagged with
      `metadata.stopped_by_user: true`), appends it to
      `state.chat_state.messages`, transitions to `:idle`,
      broadcasts `chat:message` and `chat:status`, and clears
      the bookkeeping.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.Assistant
  alias Nest.Messages.Streaming

  @doc """
  Dispatch a stop-flow message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:stop_chat, from}, state) do
    stop_chat_requested(from, state)
  end

  def handle({:chat_stopped, task_pid}, state) do
    chat_stopped(task_pid, state)
  end

  # The channel pushed `chat:stop`. Signal the in-flight chat
  # task (if any) to halt at its next blocking receive, set the
  # `cancelled` flag, and reply to the channel.
  #
  # The reply to the channel is `{:reply, :ok, ...}` because the
  # GenServer's `handle_info` returns are sent to the channel
  # pid via `send/2`; the channel's `handle_in("chat:stop", ...)`
  # only sees the `{:ok, %{}}` we already returned synchronously
  # (the channel does not block on this handle_info reply — see
  # `chat:stop` handling in `NestWeb.AgentChannel`).
  defp stop_chat_requested(_from, state) do
    state =
      case state.chat_state.chat_task_pid do
        nil ->
          # No chat task in flight; the stop is a no-op. Still set
          # the cancelled flag so any in-flight compaction
          # continuation does not auto-resume.
          %{state | chat_state: %{state.chat_state | cancelled: true}}

        task_pid when is_pid(task_pid) ->
          # `Process.send/3` is `:noconnect` and a no-op if the pid
          # is no longer alive, so a click after the chat task has
          # already completed is safe.
          send(task_pid, {:stop_chat, self()})

          %{
            state
            | chat_state: %{state.chat_state | cancelled: true}
          }
      end

    {:noreply, state}
  end

  # The chat task has finished unwinding. Finalize the partial
  # streaming accumulator into an Assistant message and
  # transition to idle. The agent's next `chat:message` push
  # will use a new `Streaming.AssistantAccumulator`.
  defp chat_stopped(_task_pid, state) do
    {:assistant, partial_assistant} = build_partial_assistant(state)

    {stamped, state} =
      Nest.Agents.Agent.__append_message__(state, {:assistant, %{partial_assistant | index: nil}})

    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | streaming_acc: nil,
            active_message_index: stamped_index,
            pending_api_logs: clear_api_logs(state, stamped_index).chat_state.pending_api_logs,
            status: :idle,
            chat_task_pid: nil,
            cancelled: false
        }
    }

    Broadcasts.status(state.id, state)

    {:noreply, state}
  end

  # Build a `%Assistant{}` from whatever text/thinking was
  # buffered in the streaming accumulator. We tag the message
  # with `metadata: %{"stopped_by_user" => true}` so the UI can
  # render a "stopped" indicator. If the chat task stopped before
  # any text was streamed (e.g. the user clicked Stop before the
  # first delta), the persisted message has `content: nil` and
  # `thinking: nil` — a deliberate "empty" assistant turn.
  #
  # The returned message has `index: nil` — the Agent stamps it
  # via `__append_message__/2` so the dual-counter bug class
  # can't recur (a budget reminder injected between the stop
  # and the unwinding would otherwise share the same index).
  defp build_partial_assistant(state) do
    case state.chat_state.streaming_acc do
      %Streaming.AssistantAccumulator{} = acc ->
        finalized = Streaming.finalize(acc)

        {:assistant,
         %Assistant{
           finalized
           | index: nil,
             timestamp: DateTime.utc_now(),
             thinking_signature: acc.thinking_signature,
             api_logs: pending_api_logs(state, acc.index),
             metadata: %{"stopped_by_user" => true}
         }}

      nil ->
        # No accumulator (e.g. the stop arrived between turns).
        # Build a placeholder so the message list is consistent.
        index = state.chat_state.active_message_index

        {:assistant,
         %Assistant{
           index: nil,
           timestamp: DateTime.utc_now(),
           content: nil,
           thinking: nil,
           tool_calls: nil,
           api_logs: pending_api_logs(state, index),
           metadata: %{"stopped_by_user" => true}
         }}
    end
  end

  # Forwarded to the GenServer module which owns the canonical
  # implementation. The `__` prefix marks them as internal.
  defp pending_api_logs(state, message_index) do
    Nest.Agents.Agent.__pending_api_logs__(state, message_index)
  end

  defp clear_api_logs(state, message_index) do
    Nest.Agents.Agent.__clear_pending_api_logs__(state, message_index)
  end
end
