defmodule Nest.Repo.Migrations.AddSpaceIdToAgents do
  @moduledoc """
  Add `space_id` to `agents` and change the unique constraint
  from `(name)` to `(space_id, name)`.

  ## Migration Steps

  1. Add nullable `space_id` FK column to `agents`
  2. Drop the unique index on `(name)`
  3. Create a unique index on `(space_id, name)`
  4. Create an index on `(space_id)` for efficient lookups
  5. Make `space_id` NOT NULL

  ## No synthetic default space

  This migration does **not** seed a default space. The
  application enforces `space_id` on every `Agents.create_agent/3`
  call (via `Nest.Spaces.create_space_with_root_agent/2` for the
  root agent of a new space, and `parent_state.space_id` for
  `clone_agent` children). The user-facing first space is created
  by `Nest.Spaces.ensure_primary_space/1` on the user's first WS
  connect.

  ## Rollback

  Drops the composite unique index, restores the original unique
  index on `(name)`, drops the `space_id` index, and removes the
  `space_id` column. No application rows are touched because the
  migration starts from a fresh-DB state (`ecto.reset`).
  """

  use Ecto.Migration

  def up do
    # Step 1: Add nullable space_id column
    alter table(:agents) do
      add :space_id, references(:spaces, on_delete: :nothing)
    end

    # Step 2: Drop old unique index on (name)
    drop_if_exists unique_index(:agents, [:name])

    # Step 3: Create unique index on (space_id, name)
    create unique_index(:agents, [:space_id, :name])

    # Step 4: Create index on space_id for efficient lookups
    create index(:agents, [:space_id])

    # Step 5: Make space_id NOT NULL
    alter table(:agents) do
      modify :space_id, :bigint, null: false
    end
  end

  def down do
    # Drop the composite unique index
    drop_if_exists unique_index(:agents, [:space_id, :name])

    # Drop the space_id index
    drop_if_exists index(:agents, [:space_id])

    # Make space_id nullable before dropping the column
    alter table(:agents) do
      modify :space_id, :bigint, null: true
    end

    # Drop the space_id column
    alter table(:agents) do
      remove_if_exists :space_id
    end

    # Restore the original unique index on (name)
    create unique_index(:agents, [:name])
  end
end
