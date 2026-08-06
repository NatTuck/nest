defmodule NestWeb.Auth.FetchCurrentUserTest do
  @moduledoc """
  Tests for `NestWeb.Auth.FetchCurrentUser` — header parsing
  and `:current_user` assignment.

  The plug must always assign `:current_user` (never raise)
  and leave anonymous requests with `nil` so downstream
  plugs can branch on it.
  """

  use NestWeb.ConnCase, async: false

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo
  alias NestWeb.Auth.FetchCurrentUser

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)
    :ok
  end

  test "assigns nil when no Authorization header is present", %{conn: conn} do
    conn = FetchCurrentUser.call(conn, [])
    assert conn.assigns.current_user == nil
  end

  test "assigns nil when the Authorization header is not Bearer", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
  end

  test "assigns nil for a malformed token", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer not-a-token")
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
  end

  test "assigns the user when the token is valid", %{conn: conn} do
    {:ok, user, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    token = AuthToken.sign(user.id)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user.id == user.id
    assert conn.assigns.current_user.username == "alice"
  end

  test "assigns nil when the token points at a deleted user", %{conn: conn} do
    {:ok, user, _} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    token = AuthToken.sign(user.id)
    Repo.delete!(user)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user == nil
  end
end
