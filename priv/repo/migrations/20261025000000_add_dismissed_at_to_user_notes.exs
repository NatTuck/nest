defmodule Nest.Repo.Migrations.AddDismissedAtToUserNotes do
  @moduledoc """
  `dismissed_at`: the human ignored a query instead of answering it.

  The advisory banner reads incoming `:query` rows with **both** `answered_at`
  and `dismissed_at` null, so a note the human does not intend to answer stops
  nudging them while the row — and the card that shows it — stays in the feed.
  The feed is the log; dropping a nudge is not deleting what was said.

  Two columns and not one, because they are two different facts: *answered* is a
  reply the agent got, *dismissed* is one it did not and will not. A query is
  never both — `Nest.Notes.mark_answered/3` clears this one — so the projection
  that renders a card has one state per row rather than a precedence to guess.

  Nothing is told to the agent that asked: a query to a human creates no debt
  and no waiter (`notes/space-chat.md`), so there is nothing to discharge and no
  refusal the agent has any use for.

  There is still no `read_at`: per-item read tracking has no UI behind it, which
  is not true of this column — the banner's Ignore button is exactly its UI.

  `:utc_datetime_usec`, like every application timestamp column since
  `20261020090000_widen_timestamp_precision.exs`; `Nest.PersistenceTest` reads
  the column type back and fails a second-precision one.
  """

  use Ecto.Migration

  def change do
    alter table(:user_notes) do
      add :dismissed_at, :utc_datetime_usec
    end
  end
end
