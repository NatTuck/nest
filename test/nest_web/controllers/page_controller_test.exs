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

  The shell is also where an instance's identity lives (tab
  title, favicon, `window.NEST_CONFIG.host`), so the last
  describe pins that here too.
  """

  # Async: the shell reads `Nest.Hostname.get/0`, which is pinned to
  # `"testhost"` by `config/test.exs`. The only module that *mutates* that
  # config is `Nest.HostnameTest`, which is deliberately `async: false` and
  # therefore runs in the serial phase after every async module has
  # finished — so a reader here can never overlap that writer.
  use NestWeb.ConnCase, async: true

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

  describe "instance identity" do
    test "titles the shell for this instance, declares its favicon, and exposes the host to the client",
         %{conn: conn} do
      body = conn |> get(~p"/register") |> html_response(200)
      document = LazyHTML.from_document(body)

      # Exact equality, not just "contains the host": no "Nest" and no
      # "Phoenix Framework" may survive in the tab.
      assert LazyHTML.text(LazyHTML.query(document, "title")) == "testhost"
      assert body =~ ~s(host: "testhost")

      icon = LazyHTML.query(document, ~s(link[rel="icon"]))
      assert LazyHTML.attribute(icon, "type") == ["image/svg+xml"]
      assert LazyHTML.attribute(icon, "href") == ["/favicon.svg"]
    end

    test "serves the favicon that static_paths/0 advertises", %{conn: conn} do
      assert "favicon.svg" in NestWeb.static_paths()
      # The stock Phoenix icon is gone and must not be advertised again.
      refute "favicon.ico" in NestWeb.static_paths()

      # `Plug.Static` serves from `priv/static`, so the list and the file must
      # agree; a mismatch makes the request fall through to the React shell.
      assert File.exists?(Application.app_dir(:nest, "priv/static/favicon.svg"))

      # End to end: the icon the shell advertises is really served as an SVG.
      # (Without it the request returns the HTML shell, so `~p"/favicon.svg"`
      # would only ever fail in a browser tab.)
      assert conn |> get(~p"/favicon.svg") |> response(200) =~ "<svg"
    end
  end
end
