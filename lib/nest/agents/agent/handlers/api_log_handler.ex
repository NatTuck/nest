defmodule Nest.Agents.Agent.Handlers.ApiLogHandler do
  @moduledoc """
  `handle_info/2` handler for `{:api_log_sequences_updated, _}`,
  dispatched by `Nest.Agents.Agent.Handlers`.

  Response logs are stored on their assistant message (persisted
  with it), so there is no separate `{:api_log, _, _}` message to
  handle — only the end-of-turn sequence bookkeeping.
  """

  @doc """
  Dispatch an api_log message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:api_log_sequences_updated, sequences}, state) do
    # The ChatTurn completed normally (no stop). Clear the
    # `chat_turn_pid` and `cancelled` flag so the next chat
    # turn can start fresh. The `:chat_idle` handler does
    # the same; this handler exists to keep the api_log
    # sequences consistent in case the Agent's lifecycle
    # state diverged (defense in depth).
    live =
      state.live
      |> Map.put(:api_log_sequences, sequences)
      |> Map.put(:chat_turn_pid, nil)
      |> Map.put(:cancelled, false)

    {:noreply, %{state | live: live}}
  end
end
