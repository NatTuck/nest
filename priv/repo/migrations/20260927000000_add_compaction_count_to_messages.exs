defmodule Nest.Repo.Migrations.AddCompactionCountToMessages do
  @moduledoc """
  Adds `messages.compaction_count`: the running number of compactions at
  that marker row (1 for the first, 2 for the second, ...).

  The collapsed history card needs exactly two numbers - how many
  compactions have happened, and where the active messages start (the
  boundary index, `agents.last_compaction_index`). Carrying the count on
  the marker means the card can be rendered without loading the archive,
  and a restart recovers the count in O(1).

  Nullable: legacy marker rows have no count. The restore path also
  recomputes the count from the loaded sequence, so a NULL is harmless.
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :compaction_count, :integer
    end
  end
end
