defmodule Nest.Agents.Agent.Handlers.ApiLogHandler do
  @moduledoc """
  `handle_info/2` handlers for API log events:
  `{:api_log, _, _}`, `{:api_log_sequences_updated, _}`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts

  @doc """
  Dispatch an api_log message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:api_log, message_index, api_log}, state) do
    api_log(message_index, api_log, state)
  end

  def handle({:api_log_sequences_updated, sequences}, state) do
    api_log_sequences_updated(sequences, state)
  end

  defp api_log(message_index, api_log, state) do
    message = find_message_by_index(state.chat_state.messages, message_index)

    if message do
      append_to_existing_message(state, message_index, api_log)
    else
      queue_for_pending_message(state, message_index, api_log)
    end
  end

  defp append_to_existing_message(state, message_index, api_log) do
    messages = Enum.map(state.chat_state.messages, &append_api_log(&1, message_index, api_log))
    updated_message = find_message_by_index(messages, message_index)

    Broadcasts.message(state.id, updated_message)

    {:noreply, %{state | chat_state: %{state.chat_state | messages: messages}}}
  end

  # Append an api_log to whichever message has the given index.
  # All four message roles (user, assistant, tool, system) share
  # the same `index` and `api_logs` fields, so a single guard
  # `when msg.index == idx` covers all of them.
  defp append_api_log({role, %{index: idx} = msg}, idx, api_log) do
    {role, %{msg | api_logs: (msg.api_logs || []) ++ [api_log]}}
  end

  defp append_api_log(msg, _idx, _api_log), do: msg

  defp queue_for_pending_message(state, message_index, api_log) do
    pending = Map.get(state.chat_state.pending_api_logs, message_index, [])

    pending_api_logs =
      Map.put(state.chat_state.pending_api_logs, message_index, pending ++ [api_log])

    {:noreply, %{state | chat_state: %{state.chat_state | pending_api_logs: pending_api_logs}}}
  end

  defp api_log_sequences_updated(sequences, state) do
    # The chat task completed normally (no stop). Clear the
    # `chat_task_pid` and `cancelled` flag so the next chat turn
    # can start fresh.
    chat_state =
      state.chat_state
      |> Map.put(:api_log_sequences, sequences)
      |> Map.put(:chat_task_pid, nil)
      |> Map.put(:cancelled, false)

    {:noreply, %{state | chat_state: chat_state}}
  end

  defp find_message_by_index(messages, idx) do
    Enum.find(messages, fn
      {_, %{index: i}} -> i == idx
      _ -> false
    end)
  end
end
