defmodule Nest.Repo.Migrations.CreateUserNotes do
  @moduledoc """
  The `user_notes` table: the transport unit, addressed, for every note that
  has a **human at one end**.

  See `notes/space-chat.md` § "What a note to a human is" and `Nest.Notes`.
  A note is not a message (`messages` is what an LLM sees) and not an inbox
  entry (that is what a process holds): it is a sender, a recipient, a kind and
  a body, and a note with a human at one end needs somewhere to live because a
  human has no process, no inbox and no transcript.

  ## Addressed, not mailbox-owned

  `from_kind`/`from_name`/`to_kind`/`to_name` rather than an owning `user_id`:
  one row per note, so a note between two humans is one row both of them read
  rather than two mirrors of it. The sigil never enters a column — `to_name` is
  the bare username, and `to_kind` is what says whether that name is a human or
  an agent. Those two columns are load-bearing rather than redundant: a human
  `nat` and an agent `nat` are different addressees and nothing else in the row
  distinguishes them.

  ## One end is human

  The check constraint is the invariant, not a convention: agent-to-agent notes
  are the inbox's, and a copy here would be a second spelling of what an agent
  was told.

  ## Indexes

  The feed is "rows in this space where I am one end", ordered by `id`, so each
  predicate gets its own index with `id` in it — the bitmap OR then needs no
  sort:

    * `(space_id, to_kind, to_name, id)` — the notes addressed to me;
    * `(space_id, from_kind, from_name, id)` — the notes I sent.

  ## Timestamps

  `:utc_datetime_usec`, like every application timestamp column since
  `20261020090000_widen_timestamp_precision.exs`; `Nest.PersistenceTest` reads
  the column type back and fails a second-precision one.

  There is no `read_at`: per-item read tracking has no UI behind it. There is no
  `updated_at`: a note's body never changes — the only write after insert is
  `answered_at`, which is what the advisory banner reads.
  """

  use Ecto.Migration

  def change do
    create table(:user_notes) do
      add :space_id, references(:spaces, on_delete: :delete_all), null: false
      add :from_kind, :string, null: false
      add :from_name, :string
      add :to_kind, :string, null: false
      add :to_name, :string, null: false
      add :content, :text, null: false
      add :kind, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :answered_at, :utc_datetime_usec
    end

    create constraint(:user_notes, :one_end_is_human,
             check: "to_kind = 'user' OR from_kind = 'user'"
           )

    create index(:user_notes, [:space_id, :to_kind, :to_name, :id])
    create index(:user_notes, [:space_id, :from_kind, :from_name, :id])
  end
end
