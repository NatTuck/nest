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

    timestamps(type: :utc_datetime_usec)
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
    # Before the validations, not after: a username is stored in its canonical
    # form, so `"Jane Doe"` is validated as `jane-doe` and a name that sanitises
    # to nothing (`"..."`, an all-CJK name) fails `validate_required` rather
    # than being stored empty.
    |> update_change(:username, &Nest.Name.sanitize/1)
    |> validate_required([:username])
    # The same rule an agent's name follows, read from its one home: the cap is
    # `Nest.Name.max_bytes/0` in bytes, not a second, character-based limit.
    |> validate_length(:username, min: 1, max: Nest.Name.max_bytes(), count: :bytes)
    |> validate_format(:username, Nest.Name.pattern(),
      message: "must contain only lowercase letters, digits, `_` and `-`"
    )
    |> unique_constraint(:username)
  end

  # The username is a `Nest.Name`: the same `[a-z0-9_-]+` rule and 255-byte cap
  # an agent's name follows, so `@Nat` and `@nat` cannot be two accounts and
  # `Nest.Name.valid?/1` is the whole rule for both. `sanitize/1` is the
  # transform; the validations above check its result, so the schema applies
  # the rule by transform **and** by check exactly as `PersistedAgent` does.
  # The underlying column is `citext`, so *comparison* is case-insensitive
  # either way — this is the stored canonical form, and it is what makes an
  # address tokenise as one token.
end
