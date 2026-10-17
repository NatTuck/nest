defmodule Nest.Repo.Migrations.WidenTimestampPrecision do
  @moduledoc """
  Widen every application timestamp column from `timestamp(0)` to
  `timestamp(6)`.

  Ecto's `:utc_datetime` emits `timestamp(0)`, so every timestamp this database
  has ever stored is a whole second. That is not a storage saving worth having:
  an instant's standard representation carries sub-second precision, and losing
  it makes two events in the same second unorderable from persisted data — which
  `Nest.Spaces.list_for_user/1`, `Nest.Accounts.list_user_invites/1` and the
  planned space feed all rely on.

  The schemas now declare `:utc_datetime_usec` and `Nest.Persistence.now/0`
  stopped truncating to match; this migration is the other half, so the columns
  agree with the schemas. `notes/timestamp-precision.md` records why the
  truncation existed and why it was wrong.

  Two tables are deliberately left alone: `schema_migrations` is Ecto's own
  bookkeeping and `agent_name_migrations` is a one-off migration's record —
  neither is application data.

  Existing values are already whole seconds, so `up/0` is lossless. `down/0` is
  **not** once this build has written anything: Postgres rounds on narrowing,
  so a rollback drops stored microseconds and can move a timestamp into the
  next second.
  """

  use Ecto.Migration

  @columns [
    {:agents, [:inserted_at, :updated_at]},
    {:blueprints, [:inserted_at, :updated_at]},
    {:invites, [:expires_at, :inserted_at, :revoked_at, :updated_at, :used_at]},
    {:messages, [:compaction_occurred_at, :inserted_at]},
    {:spaces, [:inserted_at, :updated_at]},
    {:users, [:inserted_at, :updated_at]},
    {:vocations, [:inserted_at, :updated_at]}
  ]

  def up, do: retype(:utc_datetime_usec, :utc_datetime)

  def down, do: retype(:utc_datetime, :utc_datetime_usec)

  # One `ALTER TABLE` per table, not per column. `from:` documents the type
  # being replaced and is inert here — reversibility comes from the explicit
  # `up/0`/`down/0` pair, not from `from:`.
  defp retype(to, from) do
    for {table, columns} <- @columns do
      alter table(table) do
        for column <- columns, do: modify(column, to, from: from)
      end
    end
  end
end
