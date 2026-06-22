defmodule Nest.Agents.Agent.Handlers.ExitHandler do
  @moduledoc """
  `handle_info/2` handlers for `{:EXIT, _, _}` messages from
  linked processes. Normal exits are ignored; abnormal exits
  stop the GenServer so `terminate/2` is called.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  @doc """
  Dispatch an EXIT message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:EXIT, _pid, :normal}, state) do
    # Ignore normal exits from linked processes
    {:noreply, state}
  end

  def handle({:EXIT, _pid, reason}, state) do
    # When trap_exit is enabled, EXIT signals are delivered as messages.
    # Stop the process for abnormal termination so terminate/2 is called.
    {:stop, reason, state}
  end
end
