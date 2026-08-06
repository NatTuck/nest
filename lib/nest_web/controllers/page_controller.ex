defmodule NestWeb.PageController do
  @moduledoc """
  Single-page shell. The actual UI lives in the React app
  served from `assets/`; this controller just renders the
  HTML envelope and handles the bootstrap redirects.

  ## Bootstrap flow

    * Bare `GET /` only:
      * If `Nest.Accounts.user_count/0 == 0` → redirect to
        `/register?token=first-user` so the operator can
        create the first admin without any out-of-band setup.
      * If `user_count/0 > 0` and no `Authorization: Bearer …`
        header is present → redirect to `/login`.
    * Any other path (the `/*path` catch-all — `/register`,
      `/login`, `/chat/*`, etc.) → render the React shell
      unconditionally so the client-side router can take
      over.

  The catch-all must NOT redirect on `/register` (or any
  other auth-page path) because the controller can't tell
  the difference between "user is at the bootstrap URL"
  and "redirect target". Redirecting on every wildcard
  match causes an infinite loop: `/` redirects to
  `/register?token=first-user`, which matches the wildcard,
  which redirects back, which matches the wildcard, etc.

  Both `NestWeb.Auth.FetchCurrentUser` and
  `NestWeb.Auth.RequireAuthenticated` are wired into the
  browser pipeline so the JSON `current_user` payload the
  React app needs is also available on the initial GET.
  """

  use NestWeb, :controller

  alias Nest.Accounts
  alias NestWeb.Auth

  plug Auth.FetchCurrentUser

  def home(conn, params) do
    # The router matches both `get "/"` (no wildcard, params has
    # no `"path"` key) and `get "/*path"` (params has `"path"`).
    # The bootstrap redirect is only meaningful for the bare
    # root — any other path is a real client navigation and
    # must render so the React router can decide.
    path = Map.get(params, "path", "")

    cond do
      path == "" and Accounts.user_count() == 0 ->
        redirect(conn, to: "/register?token=first-user")

      path == "" and conn.assigns[:current_user] == nil ->
        redirect(conn, to: "/login")

      true ->
        render(conn, :home)
    end
  end
end
