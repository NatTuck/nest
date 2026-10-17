defmodule Nest.Repo.Migrations.AddModeToAgentsAndBlueprints do
  use Ecto.Migration

  # A mode is a per-*agent* runtime property from here on, and every agent is
  # always in exactly one of them, so both columns are NOT NULL with the
  # permissive default: an agent nothing has said anything about may write, which
  # is what agents did before a mode was a per-agent property at all.
  #
  # The defaults are load-bearing beyond the usual reason. Every path that creates
  # an agent sets the column explicitly (from the space's blueprint, see
  # `Nest.Blueprints.Blueprint`), but test fixtures — and any other build sharing
  # this database — insert rows without it, and a NOT NULL column with no default
  # would fail them for a reason that has nothing to do with what they test.
  #
  # Existing rows need no derivation: every existing blueprint takes the same
  # default this migration gives it, so "the blueprint's `default_mode`" and the
  # column default are the same value.
  @default_mode "act"

  def up do
    alter table(:agents) do
      add :mode, :string, null: false, default: @default_mode
    end

    alter table(:blueprints) do
      add :default_mode, :string, null: false, default: @default_mode
    end
  end

  def down do
    alter table(:blueprints) do
      remove :default_mode
    end

    alter table(:agents) do
      remove :mode
    end
  end
end
