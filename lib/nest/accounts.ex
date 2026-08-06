defmodule Nest.Accounts do
  @moduledoc """
  Public API for Nest's multi-user identity layer: `users` and
  `invites`. Wraps the `Nest.Accounts.User` and
  `Nest.Accounts.Invite` Ecto schemas and the
  `Nest.Accounts.Password` / `Nest.Accounts.AuthToken` helpers
  behind a small, transaction-safe interface.

  ## Identity model

  Identity is username + password. The plaintext password never
  touches the DB — only the argon2id hash produced by
  `Nest.Accounts.Password.hash/1`. Login returns a long-lived
  `Phoenix.Token` (via `Nest.Accounts.AuthToken.sign/1`) that
  the client stores in `localStorage` and presents on every
  HTTP / WebSocket request.

  ## Permission matrix (v1)

  | Action                  | Anonymous | Authed | Admin-only? |
  |-------------------------|-----------|--------|-------------|
  | `user_count/0`          | yes       | yes    | no          |
  | `authenticate/2`        | yes       | n/a    | no          |
  | `create_user/2`         | yes       | n/a    | no          |
  | `get_user_by_token/1`   | yes       | yes    | no          |
  | `get_user/1`            | yes       | yes    | no          |
  | `create_invite/1`       | 401       | yes    | no          |
  | `redeem_invite/2`       | yes       | n/a    | no          |
  | `revoke_invite/2`       | 401       | owner  | no          |
  | `list_user_invites/1`   | 401       | self   | no          |

  "Owner" in `revoke_invite/2` means the authenticated user
  matches the invite's `created_by_user_id`. Server enforces
  via `current_user.id`; the public function also accepts the
  caller's id explicitly so it's directly testable.

  ## Magic `first-user` token

  `redeem_invite/2` accepts the literal token `"first-user"`
  only when `user_count/0 == 0`. It does not consume any
  invite row. The resulting user has `is_admin: true`. This
  is the bootstrap path for a fresh DB — the operator visits
  `/`, gets redirected to `/register?token=first-user`, and
  picks a username/password.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Changeset
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.Password
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Repo

  require Logger

  @magic_first_user_token "first-user"
  @invite_ttl_seconds 7 * 24 * 60 * 60
  @token_bytes 32

  @doc """
  Count of `users` rows. Used by the bootstrap redirect to
  decide whether to send an unauthenticated visitor to
  `/register?token=first-user` (when zero) or `/login` (when
  nonzero).
  """
  @spec user_count() :: non_neg_integer()
  def user_count do
    Repo.aggregate(UserSchema, :count)
  end

  @doc """
  Look up a user by integer id. Returns `nil` when not found;
  callers should treat that as "no such user" rather than
  raising.
  """
  @spec get_user(integer()) :: UserSchema.t() | nil
  def get_user(user_id) when is_integer(user_id) do
    Repo.get(UserSchema, user_id)
  end

  def get_user(_), do: nil

  @doc """
  Verify a Phoenix.Token and return the corresponding user.
  Returns `nil` for any failure mode — bad token, expired,
  malformed, or the encoded user no longer exists. The token
  sign/verify pair in `AuthToken` is the only thing that
  ever produces these tokens; everything else that asks for
  one is asking for trouble.
  """
  @spec get_user_by_token(String.t() | nil) :: UserSchema.t() | nil
  def get_user_by_token(token) do
    with {:ok, user_id} <- AuthToken.verify(token),
         %UserSchema{} = user <- get_user(user_id) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Register a new user. The bootstrap path (`is_admin: true` on
  first user) is automatic; subsequent calls always produce a
  non-admin user regardless of any `:is_admin` flag in
  `params`.

  When the magic token `"first-user"` is supplied AND
  `user_count/0 == 0`, no `invites` row is consumed. The user
  is created with `is_admin: true` and the call returns
  `{:ok, user, :admin}` so the caller can log the bootstrap
  event.

  For any other token, the caller must have already looked up
  the invite (or computed its eligibility). This function does
  not auto-redeem invites; see `redeem_invite/2` for that.

  ## Returns

    * `{:ok, user, :admin}` — first user, admin flag set.
    * `{:ok, user, :user}` — non-admin registration.
    * `{:error, :no_users_allowed}` — token was the magic
      `"first-user"` token but the users table is not empty.
    * `{:error, changeset}` — validation failure.
  """
  @spec create_user(map(), String.t()) ::
          {:ok, UserSchema.t(), :admin | :user} | {:error, atom() | Changeset.t()}
  def create_user(params, token) when is_map(params) and is_binary(token) do
    is_first = user_count() == 0
    is_magic = token == @magic_first_user_token

    cond do
      is_magic and not is_first ->
        {:error, :no_users_allowed}

      is_magic ->
        do_create_first_user(params)

      true ->
        do_create_user(params, false)
    end
  end

  defp do_create_first_user(params) do
    Logger.info("Bootstrapping first user via magic invite token")
    do_create_user(params, true)
  end

  defp do_create_user(params, admin?) do
    %UserSchema{}
    |> UserSchema.registration_changeset(Map.put(params, :is_admin, admin?))
    |> put_password_hash(params)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user, if(user.is_admin, do: :admin, else: :user)}
      {:error, cs} -> {:error, cs}
    end
  end

  defp put_password_hash(changeset, params) do
    case Map.fetch(params, :password) do
      {:ok, plaintext} when is_binary(plaintext) and byte_size(plaintext) > 0 ->
        changeset
        |> put_change(:password_hash, Password.hash(plaintext))

      _ ->
        add_error(changeset, :password, "is required")
    end
  end

  @doc """
  Authenticate a user by username + plaintext password.

  ## Returns

    * `{:ok, user}` — credentials valid.
    * `{:error, :invalid_credentials}` — no such user, or the
      stored hash didn't verify. The two failure modes are
      deliberately indistinguishable to the caller so a
      timing-attack-resistant login form can return a single
      generic error message.
    * `{:error, :missing_fields}` — `username` or `password`
      was missing or not a binary.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, :invalid_credentials | :missing_fields}
  def authenticate(username, password)
      when is_binary(username) and is_binary(password) do
    username = username |> String.trim() |> String.downcase()

    case Repo.get_by(UserSchema, username: username) do
      %UserSchema{password_hash: hash} = user when is_binary(hash) ->
        if Password.verify(password, hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      _ ->
        # Still hash the supplied password so the request
        # takes roughly the same time as a real success path.
        # Without this, an attacker can tell apart
        # "no such user" from "wrong password" by timing.
        Password.hash(password)
        {:error, :invalid_credentials}
    end
  end

  def authenticate(_username, _password), do: {:error, :missing_fields}

  @doc """
  Issue a fresh invite as the given user. Returns the row and
  the URL-safe base64 token in the same shape the registration
  page expects.

  ## Returns

    * `{:ok, invite, token}` — invite created; `token` is the
      url-safe-base64 string stored verbatim in `invites.token`
      (the same string the recipient pastes into `/register`).
    * `{:error, changeset}` — validation failure (shouldn't
      happen in practice; the function fills every required
      field).
  """
  @spec create_invite(integer()) ::
          {:ok, InviteSchema.t(), String.t()} | {:error, Changeset.t()}
  def create_invite(user_id) when is_integer(user_id) do
    token = generate_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@invite_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %InviteSchema{}
    |> InviteSchema.new_changeset(%{
      token: token,
      created_by_user_id: user_id,
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, invite} -> {:ok, invite, token}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Redeem an invite token. Validates the token (not used, not
  revoked, not expired), creates the new user, and marks the
  invite as used — all inside a single transaction so the
  two writes commit atomically. The user gets `is_admin:
  false`; the magic `first-user` token is handled by
  `create_user/2` instead, before this function is reached.

  ## Returns

    * `{:ok, user}` — registration succeeded.
    * `{:error, :invalid_token}` — no such invite.
    * `{:error, :already_used}` — invite has a `used_at`.
    * `{:error, :revoked}` — invite has a `revoked_at`.
    * `{:error, :expired}` — `expires_at` is in the past.
    * `{:error, changeset}` — user-row validation failed.
  """
  @spec redeem_invite(String.t(), map()) ::
          {:ok, UserSchema.t()} | {:error, atom() | Changeset.t()}
  def redeem_invite(token, params) when is_binary(token) and is_map(params) do
    case Repo.get_by(InviteSchema, token: token) do
      nil ->
        {:error, :invalid_token}

      %InviteSchema{used_at: used_at} when not is_nil(used_at) ->
        {:error, :already_used}

      %InviteSchema{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %InviteSchema{expires_at: expires_at} = invite ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          {:error, :expired}
        else
          do_redeem(invite, params)
        end
    end
  end

  defp do_redeem(invite, params) do
    Repo.transaction(fn ->
      with {:ok, user, _role} <- do_create_user(params, false),
           {:ok, _invite} <-
             invite
             |> InviteSchema.redeem_changeset(
               user.id,
               DateTime.utc_now() |> DateTime.truncate(:second)
             )
             |> Repo.update() do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, _} = err -> err
    end
  end

  @doc """
  Revoke an invite. Only the user who created the invite may
  revoke it.

  ## Returns

    * `:ok` — invite was already revoked, OR was successfully
      revoked now.
    * `{:error, :not_found}` — no such invite.
    * `{:error, :forbidden}` — invite exists but `caller_id`
      doesn't match its creator.
    * `{:error, :already_used}` — invite has been redeemed;
      cannot be revoked.
  """
  @spec revoke_invite(integer(), integer()) ::
          :ok | {:error, :not_found | :forbidden | :already_used}
  def revoke_invite(invite_id, caller_id)
      when is_integer(invite_id) and is_integer(caller_id) do
    case Repo.get(InviteSchema, invite_id) do
      nil ->
        {:error, :not_found}

      %InviteSchema{used_at: ua} when not is_nil(ua) ->
        {:error, :already_used}

      %InviteSchema{created_by_user_id: c, revoked_at: r} = invite ->
        cond do
          c != caller_id ->
            {:error, :forbidden}

          r ->
            :ok

          true ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)
            {:ok, _} = invite |> InviteSchema.revoke_changeset(now) |> Repo.update()
            :ok
        end

      %InviteSchema{} ->
        {:error, :forbidden}
    end
  end

  @doc """
  List the invites a user has created, newest first. Includes
  used and revoked invites so the user can see history.
  """
  @spec list_user_invites(integer()) :: [InviteSchema.t()]
  def list_user_invites(user_id) when is_integer(user_id) do
    from(i in InviteSchema,
      where: i.created_by_user_id == ^user_id,
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  # 32 bytes of cryptographically-strong randomness, returned
  # as a URL-safe base64 string (43 chars, no padding). The same
  # string is stored in `invites.token` and presented to the user
  # as their invite URL fragment.
  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
