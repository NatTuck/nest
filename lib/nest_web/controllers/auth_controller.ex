defmodule NestWeb.AuthController do
  @moduledoc """
  JSON API for username + password authentication under `/api/v1`.

  All endpoints accept JSON request bodies (`application/json`)
  and return JSON responses. Auth tokens are long-lived
  `Phoenix.Token`s (`Nest.Accounts.AuthToken`) stored on the
  client in `localStorage` and sent as `Authorization: Bearer
  <token>` on subsequent requests.

  ## Endpoints

    * `POST /api/v1/login` — `{username, password}` → `{token, user}`
      on success, 401 on bad credentials, 400 on missing fields.
    * `POST /api/v1/register` — `{username, password, token}` →
      `{token, user}`. The `token` is either an invite token
      issued by an existing user, or the magic `"first-user"`
      token accepted only when the users table is empty.
    * `POST /api/v1/logout` — no-op (the client just discards its
      `localStorage` entry). Returns 204.
  """

  use NestWeb, :controller

  alias Nest.Accounts

  @magic_first_user_token "first-user"

  def login(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        token = Accounts.AuthToken.sign(user.id)

        json(conn, %{
          token: token,
          user: public_user(user)
        })

      {:error, :invalid_credentials} ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})

      {:error, :missing_fields} ->
        conn
        |> put_status(400)
        |> json(%{error: "missing_fields"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing_fields"})
  end

  def register(conn, %{
        "username" => username,
        "password" => password,
        "token" => invite_token
      }) do
    case invite_token do
      @magic_first_user_token ->
        register_via_magic_token(conn, username, password)

      token when is_binary(token) ->
        register_via_invite(conn, token, username, password)

      _ ->
        conn
        |> put_status(400)
        |> json(%{error: "missing_fields"})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing_fields"})
  end

  # The magic `"first-user"` token is only valid when the users
  # table is empty. `Accounts.create_user/2` enforces this; we
  # map the error to a 409 (conflict) so the UI can show a
  # "users already exist" message.
  defp register_via_magic_token(conn, username, password) do
    case Accounts.create_user(%{username: username, password: password}, @magic_first_user_token) do
      {:ok, user, role} ->
        sign_in_and_respond(conn, user, role)

      {:error, :no_users_allowed} ->
        conn
        |> put_status(409)
        |> json(%{error: "users_already_exist"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(changeset_errors_to_json(changeset))
    end
  end

  defp register_via_invite(conn, invite_token, username, password) do
    case Accounts.redeem_invite(invite_token, %{username: username, password: password}) do
      {:ok, user} ->
        sign_in_and_respond(conn, user, :user)

      {:error, :invalid_token} ->
        conn
        |> put_status(404)
        |> json(%{error: "invalid_invite"})

      {:error, :already_used} ->
        conn
        |> put_status(409)
        |> json(%{error: "invite_already_used"})

      {:error, :revoked} ->
        conn
        |> put_status(409)
        |> json(%{error: "invite_revoked"})

      {:error, :expired} ->
        conn
        |> put_status(409)
        |> json(%{error: "invite_expired"})

      {:error, changeset} ->
        conn
        |> put_status(422)
        |> json(changeset_errors_to_json(changeset))
    end
  end

  defp sign_in_and_respond(conn, user, _role) do
    token = Accounts.AuthToken.sign(user.id)
    json(conn, %{token: token, user: public_user(user)})
  end

  # Convert an Ecto.Changeset into a JSON-friendly error map
  # with the same `field: ["message"]` shape the test stack
  # already consumes via `DataCase.errors_on/1`. The JS side
  # renders these per-field toasts.
  defp changeset_errors_to_json(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.put(:error, "validation_failed")
  end

  # JSON-safe slice of the user. The `password_hash` column is
  # excluded by `Nest.Accounts.User`'s `@derive {Jason.Encoder,
  # only: [...]}` — the struct's `:password_hash` field is set
  # to `nil` by `UserSchema.registration_changeset` and never
  # round-trips through encode/1 in a way that would leak it.
  defp public_user(user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin == true
    }
  end

  def logout(conn, _params) do
    # The server has no session to clear — the token lives on
    # the client. Return 204 so the client can chain a
    # `localStorage.removeItem("token")` on `.then(...)`.
    send_resp(conn, 204, "")
  end
end
