defmodule Nest.Repo.Migrations.AddWorkspacePathToSpaces do
  @moduledoc """
  Add `workspace_path` to `spaces`.

  The workspace becomes a space-level property that agents inherit
  (root agents default to the space's path; sub-agents inherit from
  their parent). Agents keep their own `workspace_path` (which
  defaults from the space at creation) so an agent can still override
  it, but the space is the canonical owner.

  Nullable — a space (e.g. the Chat blueprint) may have no workspace.
  """

  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :workspace_path, :string
    end
  end
end
