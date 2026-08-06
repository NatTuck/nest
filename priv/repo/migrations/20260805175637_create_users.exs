defmodule Nest.Repo.Migrations.CreateUsers do
  @moduledoc """
  The `users` table — one row per Nest user.

  Identity is username + password. The `username` is `citext`
  (case-insensitive) so logins aren't sensitive to capitalization;
  a unique index enforces uniqueness regardless of case.

  `password_hash` holds the argon2id-encoded hash produced by
  `Argon2.hash_pwd_salt/1` (the default `$argon2id$v=19$m=…`
  format from the `argon2_elixir` library). The plaintext never
  touches the DB.

  `is_admin` is a one-way flag set by the application on first
  registration (`user_count == 0` → admin). Not used for
  authorization in v1, but reserved for follow-up admin-only
  operations (e.g. restricting invite generation).

  The bigserial `id` matches the integer-PK convention used by
  `agents`, `messages`, and `vocations`. Foreign keys from
  `invites.created_by_user_id` and `agents.created_by_user_id`
  point at this column.
  """

  use Ecto.Migration

  def change do
    # Per-database. citext is bundled with Postgres but not enabled
    # by default; the first migration that needs it creates it. The
    # `IF NOT EXISTS` clause makes the migration safe to re-run on
    # a DB that already has the extension loaded.
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    create table(:users, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :username, :citext, null: false
      add :password_hash, :binary, null: false
      add :is_admin, :boolean, default: false, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:users, [:username])
  end
end
