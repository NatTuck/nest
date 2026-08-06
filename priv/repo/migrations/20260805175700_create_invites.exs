defmodule Nest.Repo.Migrations.CreateInvites do
  @moduledoc """
  The `invites` table — cryptographic one-time invitation tokens.

  ## Lifecycle

  1. An authenticated user calls `Accounts.create_invite/1`, which
     inserts a row with a fresh 32-byte `token` (URL-safe base64)
     and `expires_at = NOW + 7 days`. `used_by_user_id`, `used_at`,
     and `revoked_at` are NULL.
  2. The user shares the token out-of-band. The recipient opens
     `/register?token=…` and submits their credentials.
  3. `Accounts.redeem_invite/2` validates the token (not used,
     not revoked, not expired) inside a single transaction that
     also marks the invite as used and inserts the new `users`
     row. The two writes commit atomically — a redeem that
     succeeds always produces a used invite, and vice versa.

  ## Magic `first-user` token

  The token `"first-user"` is a special case accepted by
  `Accounts.redeem_invite/2` only when the `users` table is empty.
  It does **not** consume any invite row and produces a user with
  `is_admin: true`. This is the bootstrap path for a fresh DB —
  the operator visits `/`, is redirected to `/register?token=
  first-user`, picks a username/password, and the system becomes
  multi-user-ready without any out-of-band setup.
  """

  use Ecto.Migration

  def change do
    create table(:invites, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :token, :string, null: false
      add :created_by_user_id, references(:users, on_delete: :restrict), null: false
      add :expires_at, :utc_datetime, null: false
      add :used_by_user_id, references(:users, on_delete: :nilify_all)
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:invites, [:token])
    create index(:invites, [:created_by_user_id])
  end
end
