defmodule NestWeb.PageControllerTest do
  @moduledoc """
  Tests for `NestWeb.PageController.home/2`.

  The controller branches on the request path. The bare `/`
  is the bootstrap entrypoint: with no users it redirects
  to `/register?token=first-user`; with users but no auth
  it redirects to `/login`. Anything else (the `/*path`
  catch-all) renders the React shell unconditionally so
  client-side routing can take over.

  The wildcard must NOT redirect to `/register` when the
  user is already at `/register` — that produces an
  infinite 302 loop. The tests below pin that behavior.
  """

  use NestWeb.ConnCase, async: false

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)
    :ok
  end

  describe "bare / bootstrap" do
    test "redirects to /register?token=first-user when no users exist", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn, 302) == "/register?token=first-user"
    end

    test "redirects to /login when users exist but the request is anonymous",
         %{conn: conn} do
      {:ok, _, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      conn = get(conn, ~p"/")
      assert redirected_to(conn, 302) == "/login"
    end

    test "renders the shell when users exist and the request is authenticated",
         %{conn: conn} do
      {:ok, user, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      token = AuthToken.sign(user.id)
      conn = put_req_header(conn, "authorization", "Bearer #{token}")
      conn = get(conn, ~p"/")
      assert html_response(conn, 200)
    end
  end

  describe "/*path catch-all" do
    test "renders the shell for /register?token=first-user with no users (not a redirect loop)",
         %{conn: conn} do
      conn = get(conn, ~p"/register?token=first-user")
      assert html_response(conn, 200)
    end

    test "renders the shell for /login when anonymous and users exist",
         %{conn: conn} do
      {:ok, _, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      conn = get(conn, ~p"/login")
      assert html_response(conn, 200)
    end

    test "renders the shell for /login when authenticated",
         %{conn: conn} do
      {:ok, user, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      token = AuthToken.sign(user.id)
      conn = put_req_header(conn, "authorization", "Bearer #{token}")
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200)
    end

    test "renders the shell for /chat/anything when authenticated",
         %{conn: conn} do
      {:ok, user, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      token = AuthToken.sign(user.id)
      conn = put_req_header(conn, "authorization", "Bearer #{token}")
      conn = get(conn, ~p"/chat/abc")
      assert html_response(conn, 200)
    end
  end
end
