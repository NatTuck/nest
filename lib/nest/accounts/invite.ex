defmodule Nest.Accounts.Invite do
  @moduledoc """
  Ecto schema for the `invites` table — cryptographic one-time
  invitation tokens. See `Nest.Accounts` for the public API and
  the migration's moduledoc for the lifecycle.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :created_by_user_id,
             :expires_at,
             :used_by_user_id,
             :used_at,
             :revoked_at,
             :inserted_at,
             :updated_at
           ]}

  schema "invites" do
    field :token, :string
    field :created_by_user_id, :integer
    field :expires_at, :utc_datetime
    field :used_by_user_id, :integer
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          token: binary() | nil,
          created_by_user_id: integer() | nil,
          expires_at: DateTime.t() | nil,
          used_by_user_id: integer() | nil,
          used_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Build a changeset for inserting a fresh invite. `Nest.Accounts.
  create_invite/2` populates `:token` and `:expires_at` before
  calling this — the caller never supplies them.
  """
  def new_changeset(source, params) do
    source
    |> cast(params, [:token, :created_by_user_id, :expires_at])
    |> validate_required([:token, :created_by_user_id, :expires_at])
    |> validate_length(:token, min: 16, max: 128)
    |> unique_constraint(:token)
  end

  @doc """
  Build a changeset for marking an invite as redeemed. Both
  `:used_by_user_id` and `:used_at` are set together so the
  database never observes a "used without by" half-state.
  """
  def redeem_changeset(source, user_id, used_at) do
    source
    |> cast(%{used_by_user_id: user_id, used_at: used_at}, [:used_by_user_id, :used_at])
    |> validate_required([:used_by_user_id, :used_at])
    |> foreign_key_constraint(:used_by_user_id)
  end

  @doc """
  Build a changeset for revoking an invite. Sets `:revoked_at`.
  Idempotent — re-revoking is a no-op at the application layer
  (revoke once, all later revoke calls hit the same row).
  """
  def revoke_changeset(source, revoked_at) do
    source
    |> cast(%{revoked_at: revoked_at}, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
