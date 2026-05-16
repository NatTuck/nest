defmodule Nest.Agents.Registry do
  @moduledoc """
  Registry for agent process lookup by readable ID.

  Uses Elixir's Registry module with unique keys to ensure each agent
  has a unique identifier that can be used to locate its process.
  """

  @registry_name __MODULE__

  @doc """
  Returns the child specification for starting the Registry under a supervisor.
  """
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    Registry.child_spec(
      keys: :unique,
      name: @registry_name
    )
  end

  @doc """
  Returns a via tuple for looking up an agent process by its ID.

  This tuple can be used with GenServer calls to address the agent
  without knowing its PID.

  ## Examples

      iex> Nest.Agents.Registry.via_tuple("clever-raven")
      {:via, Registry, {Nest.Agents.Registry, "clever-raven"}}

  """
  @spec via_tuple(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via_tuple(agent_id) do
    {:via, Registry, {@registry_name, agent_id}}
  end

  @doc """
  Looks up an agent process by its ID.

  Returns `{:ok, pid}` if the agent is running, or `{:error, :not_found}`
  if no agent exists with that ID.

  ## Examples

      iex> Nest.Agents.Registry.lookup("clever-raven")
      {:ok, #PID<0.123.0>}

      iex> Nest.Agents.Registry.lookup("nonexistent")
      {:error, :not_found}

  """
  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(agent_id) do
    case Registry.lookup(@registry_name, agent_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all registered agent IDs.

  ## Examples

      iex> Nest.Agents.Registry.list()
      ["clever-raven", "swift-fox"]

  """
  @spec list() :: list(String.t())
  def list do
    Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
