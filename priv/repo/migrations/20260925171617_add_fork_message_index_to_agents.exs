defmodule Nest.Repo.Migrations.AddForkMessageIndexToAgents do
  @moduledoc """
  Adds `agents.fork_message_index`: the clone's first own
  `message_index`.

  A clone shares its ancestors' rows below this index and owns rows
  at or above it (see `notes/shared-message-structure.md`). `NULL`
  means the agent owns its full sequence from index 0 — a root, a
  fresh child, or a clone that has detached at compaction. Existing
  rows are all roots/fresh children, so the backfill is `NULL`.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :fork_message_index, :integer
    end
  end
end
