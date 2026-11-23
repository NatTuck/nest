defmodule Nest.Spaces.MaxAgents do
  @moduledoc """
  The space's cap on non-archived agents (`Nest.Agents.StartGuard`), edited on
  its own like `Nest.Spaces.ContextWarnings`.

  The value is a **space** property, copied from the blueprint at creation
  (`Nest.Spaces.CreationParams`) and owned independently thereafter. It is not
  part of the sandbox environment: nothing about it reaches a command, so it is
  not on `Nest.Sandbox.Mounts`, and a save stops nothing, releases nothing, and
  owes no notice — hence one column write, and no latch.

  The cap gates **spawning only**; lowering it below the current team size does
  not stop or archive anyone, it only refuses new spawns until the space is back
  under the cap.
  """

  alias Nest.Repo
  alias Nest.Spaces.Space

  @doc """
  Set `space`'s agent cap, returning the row as it now stands.

  A value the row already holds writes nothing — `Ecto.Changeset.change/2`
  records no change for it, and `Repo.update/1` sends no query for an empty
  changeset. The caller validates the value is a positive integer before this
  (the edit payload gate); the guard here keeps the contract total.
  """
  @spec set(Space.t(), pos_integer()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def set(%Space{} = space, value) when is_integer(value) and value > 0 do
    space
    |> Ecto.Changeset.change(max_agents: value)
    |> Repo.update()
  end
end
