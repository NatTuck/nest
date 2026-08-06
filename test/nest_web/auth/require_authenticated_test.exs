defmodule NestWeb.Auth.RequireAuthenticatedTest do
  @moduledoc """
  Tests for `NestWeb.Auth.RequireAuthenticated` — 401
  enforcement for anonymous requests and pass-through for
  authenticated requests.

  The plug always assigns `nil` to `:current_user` when no
  Authorization header is present (via `FetchCurrentUser`),
  so the unauthenticated path is the only one this plug
  blocks.
  """

  use NestWeb.ConnCase, async: false

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo
  alias NestWeb.Auth.FetchCurrentUser
  alias NestWeb.Auth.RequireAuthenticated

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)
    :ok
  end

  test "halts with 401 + JSON body when current_user is nil", %{conn: conn} do
    # FetchCurrentUser runs first and assigns nil.
    conn =
      conn
      |> FetchCurrentUser.call([])
      |> RequireAuthenticated.call([])

    assert conn.status == 401
    assert conn.halted
    assert json_response(conn, 401) == %{"error" => "unauthenticated"}
  end

  test "passes through when current_user is set", %{conn: conn} do
    {:ok, user, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    token = AuthToken.sign(user.id)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> FetchCurrentUser.call([])
      |> RequireAuthenticated.call([])

    refute conn.halted
    assert conn.status != 401
    assert conn.assigns.current_user.id == user.id
  end
end
