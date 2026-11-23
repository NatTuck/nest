defmodule Nest.Repo.Migrations.AddMaxAgentsToBlueprints do
  use Ecto.Migration

  # A blueprint is where a space's *defaults* live, and the cap on how many
  # non-archived agents a space may hold is one of them (#225): the team a
  # blueprint describes has a size, and a Grading space's twenty graders are
  # not a Chat space's one conversationalist.
  #
  # Deliberately **nullable**: `NULL` means "this blueprint does not say", and
  # the gate reads it as the default (`Nest.Agents.StartGuard`). No backfill —
  # every existing blueprint keeps the default it already had, which is what
  # the gate applied before this column existed.
  #
  # The CHECK is the canonical guard that a set limit is a positive integer;
  # `Blueprint.changeset/2` surfaces the same rule as a changeset error so a
  # caller hears it before the DB raises.
  def up do
    alter table(:blueprints) do
      add :max_agents, :integer
    end

    create constraint(:blueprints, :max_agents_positive,
             check: "max_agents IS NULL OR max_agents > 0"
           )
  end

  def down do
    drop constraint(:blueprints, :max_agents_positive)

    alter table(:blueprints) do
      remove :max_agents
    end
  end
end
