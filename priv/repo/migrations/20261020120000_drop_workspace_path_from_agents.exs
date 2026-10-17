defmodule Nest.Repo.Migrations.DropWorkspacePathFromAgents do
  @moduledoc """
  Drop `agents.workspace_path`: the workspace is the *space's*.

  `spaces.workspace_path` is the value, and it is what an agent inherits —
  `Nest.Agents.Agent.Init` builds the agent's `Nest.Sandbox.Mounts` from it at
  start. The per-agent column was only ever written by inheritance
  (`Agents.create_agent/3`'s `:workspace_path` option, a spawned child copying
  its parent's mounts, a clone doing the same), so it was a second spelling of
  one value that could drift — and a field on a struct that is at credo's
  field cap.

  No data step: every value in the column was a copy of the space's, and the
  space's is still there.
  """

  use Ecto.Migration

  def up do
    alter table(:agents) do
      remove :workspace_path
    end
  end

  def down do
    alter table(:agents) do
      add :workspace_path, :string
    end
  end
end
