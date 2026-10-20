defmodule NestWeb.Auth.RequireAuthenticatedTest do
  @moduledoc """
  Tests for `NestWeb.Auth.RequireAuthenticated` — 401
  enforcement for anonymous requests and pass-through for
  authenticated requests.

  The plug branches only on `conn.assigns[:current_user]`:
  `nil` halts with a JSON 401, anything else is returned
  untouched. How `:current_user` gets set is
  `FetchCurrentUser`'s job, tested in
  `test/nest_web/auth/fetch_current_user_test.exs`.
  """

  # Async: the plug only branches on `conn.assigns.current_user` and
  # halts; it touches no global state.
  use NestWeb.ConnCase, async: true

  alias NestWeb.Auth.FetchCurrentUser
  alias NestWeb.Auth.RequireAuthenticated

  test "halts with 401 + JSON body when current_user is nil", %{conn: conn} do
    # FetchCurrentUser runs first and assigns nil.
    conn =
      conn
      |> FetchCurrentUser.call([])
      |> RequireAuthenticated.call([])

    assert conn.halted
    assert json_response(conn, 401) == %{"error" => "unauthenticated"}
  end

  test "passes through when current_user is set", %{conn: conn} do
    conn =
      conn
      |> assign(:current_user, %{id: 1})
      |> RequireAuthenticated.call([])

    refute conn.halted
    assert conn.status != 401
  end
end
