defmodule Nest.Repo.Migrations.AddMaxAgentsToSpaces do
  use Ecto.Migration

  # The space's own cap on non-archived agents (#225). Model B: the value is
  # **copied from the blueprint at creation** and the space owns it independently
  # thereafter — a later blueprint change does not move an existing space's cap,
  # and the edit-space screen edits this column, not the blueprint.
  #
  # NOT NULL with a default of 5: every space has a cap. Existing rows are
  # backfilled from their blueprint's `max_agents` (or 5 when the blueprint names
  # none or is absent), which is the cap the gate applied to them before this
  # column existed — so no space's effective limit changes by the migration.
  #
  # The CHECK is the canonical guard that a cap is a positive integer;
  # `Space.changeset/2` surfaces the same rule as a changeset error.
  def up do
    alter table(:spaces) do
      add :max_agents, :integer, null: false, default: 5
    end

    create constraint(:spaces, :max_agents_positive, check: "max_agents > 0")

    execute """
    UPDATE spaces
    SET max_agents = COALESCE(
      (SELECT b.max_agents FROM blueprints b WHERE b.id = spaces.blueprint_id),
      5
    )
    """
  end

  def down do
    drop constraint(:spaces, :max_agents_positive)

    alter table(:spaces) do
      remove :max_agents
    end
  end
end
