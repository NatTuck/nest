defmodule NestWeb.InviteController do
  @moduledoc """
  JSON API for managing invites under `/api/v1/invites`.

  All endpoints require authentication — the `RequireAuthenticated`
  plug halts anonymous requests with 401 before they reach this
  module. The current user is fetched via `FetchCurrentUser` and
  available as `conn.assigns.current_user`.

  ## Endpoints

    * `POST /api/v1/invites` — issue a fresh invite under the
      caller's name. Returns 201 + `{id, token, expires_at, …}`.
    * `GET /api/v1/invites` — list the caller's invites,
      newest first (used + unused).
    * `DELETE /api/v1/invites/:id` — revoke an invite the
      caller issued. Returns 204 on success, 403 if the invite
      belongs to someone else, 409 if it was already used.

  In v1 every authenticated user can create invites; an
  admin-only mode is a follow-up.
  """

  use NestWeb, :controller

  alias Nest.Accounts

  def index(conn, _params) do
    user = conn.assigns.current_user

    invites =
      user.id
      |> Accounts.list_user_invites()
      |> Enum.map(&public_invite/1)

    json(conn, %{invites: invites})
  end

  def create(conn, _params) do
    user = conn.assigns.current_user

    case Accounts.create_invite(user.id) do
      {:ok, invite, token} ->
        # The plaintext token is returned ONCE here; clients
        # should display it for the user to copy and never
        # re-fetch it (the stored hash isn't recoverable).
        conn
        |> put_status(201)
        |> json(public_invite(invite) |> Map.put(:token, token))

      {:error, _changeset} ->
        conn
        |> put_status(500)
        |> json(%{error: "failed_to_create_invite"})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Integer.parse(id) do
      {int_id, _} ->
        case Accounts.revoke_invite(int_id, user.id) do
          :ok ->
            send_resp(conn, 204, "")

          {:error, :not_found} ->
            conn
            |> put_status(404)
            |> json(%{error: "not_found"})

          {:error, :forbidden} ->
            conn
            |> put_status(403)
            |> json(%{error: "forbidden"})

          {:error, :already_used} ->
            conn
            |> put_status(409)
            |> json(%{error: "already_used"})
        end

      :error ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_id"})
    end
  end

  # Public-shape invite. Drops the token by default (server
  # doesn't store the plaintext); the `create` action
  # overrides `token` in the response so the caller can copy
  # it out to share.
  defp public_invite(invite) do
    %{
      id: invite.id,
      created_by_user_id: invite.created_by_user_id,
      expires_at: invite.expires_at,
      used_by_user_id: invite.used_by_user_id,
      used_at: invite.used_at,
      revoked_at: invite.revoked_at,
      inserted_at: invite.inserted_at
    }
  end
end
