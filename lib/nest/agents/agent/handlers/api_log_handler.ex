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
    # API-log sequence bookkeeping. The turn stores these directly now;
    # this handler remains for defense in depth.
    live =
      state.live
      |> Map.put(:api_log_sequences, sequences)
      |> Map.put(:cancelled, false)

    {:noreply, %{state | live: live}}
  end
end
