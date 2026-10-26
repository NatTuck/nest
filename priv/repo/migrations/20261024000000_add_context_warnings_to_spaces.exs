defmodule Nest.Repo.Migrations.AddContextWarningsToSpaces do
  use Ecto.Migration

  # Context-usage notices are opt-in per space from here on (issue #176). The
  # notices were meant to be helpful, but an agent can read one as "stop now",
  # which is the opposite of what the threshold means, so the default is off and
  # a space turns them on deliberately.
  #
  # No backfill: unlike `network_access`, there is nothing to derive — the
  # column's `default: false` is the intended value for every existing space, not
  # a copy of anything its agents had.
  def up do
    alter table(:spaces) do
      add :context_warnings, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:spaces) do
      remove :context_warnings
    end
  end
end
