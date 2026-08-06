defmodule NestWeb.Auth.FetchCurrentUser do
  @moduledoc """
  Plug that reads the `Authorization: Bearer <token>` header,
  validates the token via `Nest.Accounts.AuthToken`, and
  assigns `:current_user` on `conn.assigns`. Anonymous requests
  pass through with `:current_user` left at `nil` so downstream
  plugs can branch on it.

  Use this plug as the FIRST step of any pipeline that needs
  user context (HTTP `/api/v1/*`, browser pages that show
  "logged in as X", etc.). Combine with
  `NestWeb.Auth.RequireAuthenticated` to enforce auth.

  Token failures (missing, malformed, tampered, expired) are
  treated the same as anonymous access — the plug never halts.
  Authentication enforcement is the job of the dedicated
  `RequireAuthenticated` plug. This split lets the same
  pipeline support endpoints that should render differently
  for authed vs. anonymous users without a redirect dance.
  """

  import Plug.Conn

  alias Nest.Accounts

  def init(opts), do: opts

  @header "authorization"
  @bearer_prefix "Bearer "

  def call(conn, _opts) do
    current_user = current_user_from_header(conn)

    conn
    |> assign(:current_user, current_user)
  end

  defp current_user_from_header(conn) do
    case get_req_header(conn, @header) do
      [@bearer_prefix <> token] ->
        Accounts.get_user_by_token(token)

      _ ->
        nil
    end
  end
end
