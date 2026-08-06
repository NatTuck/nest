defmodule Nest.Accounts.User do
  @moduledoc """
  Ecto schema for the `users` table. One row per Nest user.

  See `Nest.Accounts` for the public API (creation, authentication,
  token verification). The schema is the persistence-side mirror
  of the runtime `current_user` struct that the `UserSocket` and
  HTTP plugs put on `socket.assigns` / `conn.assigns`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :username,
             :is_admin,
             :inserted_at,
             :updated_at
           ]}

  schema "users" do
    field :username, :string
    field :password_hash, :binary
    field :is_admin, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          username: String.t() | nil,
          password_hash: binary() | nil,
          is_admin: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Build a changeset for inserting a user. The caller is
  responsible for hashing the plaintext password before calling
  this — `Nest.Accounts.create_user/2` does so via
  `Nest.Accounts.Password.hash/1`.

  Casts `:username`, `:password_hash`, and `:is_admin`.
  `:is_admin` is set by the application on first registration
  only; subsequent calls always ignore it.
  """
  def registration_changeset(source, params) do
    source
    |> cast(params, [:username, :password_hash, :is_admin])
    |> validate_required([:username])
    |> validate_length(:username, min: 1, max: 64)
    |> update_change(:username, &normalize_username/1)
    |> unique_constraint(:username)
  end

  # Lowercase + trim the username so case and surrounding
  # whitespace can't cause duplicate-looking accounts. The
  # underlying column is `citext`, so the comparison is
  # case-insensitive; we still normalize on the way in so
  # the canonical form is what gets stored.
  defp normalize_username(nil), do: nil

  defp normalize_username(username) when is_binary(username) do
    username |> String.trim() |> String.downcase()
  end
end
