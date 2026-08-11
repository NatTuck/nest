defmodule Nest.Agents.Registry do
  @moduledoc """
  Registry for agent lookup by `{space_id, name}`.

  Uses Elixir's `Registry` with unique keys to ensure each
  agent has a unique identifier within its space. The key
  tuple is `{space_id, name}` — agents are unique within a
  space, not globally.
  """

  @registry __MODULE__

  @doc """
  Returns the child specification for starting the Registry under a supervisor.
  """
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    Registry.child_spec(
      keys: :unique,
      name: @registry
    )
  end

  @doc """
  Returns a via tuple for looking up an agent by its
  `{space_id, name}`.

  ## Examples

      iex> Nest.Agents.Registry.via_tuple(1, "clever-raven")
      {:via, Registry, {Nest.Agents.Registry, {1, "clever-raven"}}}

  """
  @spec via_tuple(integer(), String.t()) :: {:via, Registry, {atom(), {integer(), String.t()}}}
  def via_tuple(space_id, name) do
    {:via, Registry, {@registry, {space_id, name}}}
  end

  @doc """
  Looks up an agent by its `{space_id, name}`.

  Returns `{:ok, pid}` if the agent is running, or
  `{:error, :not_found}` if no agent exists with that key.
  """
  @spec lookup(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(space_id, name) do
    case Registry.lookup(@registry, {space_id, name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all agent names in a given space.
  """
  @spec list_for_space(integer()) :: list(String.t())
  def list_for_space(space_id) do
    @registry
    |> Registry.select([{{{:"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {sid, _name} -> sid == space_id end)
    |> Enum.map(fn {_sid, name} -> name end)
  end

  @doc """
  Returns a list of all registered `{space_id, name}` tuples.
  """
  @spec list_all() :: list({integer(), String.t()})
  def list_all do
    Registry.select(@registry, [{{{:"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
