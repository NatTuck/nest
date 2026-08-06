defmodule NestWeb.Auth.RequireAuthenticated do
  @moduledoc """
  Plug that halts the connection with `401 Unauthorized` when
  no `:current_user` was assigned by
  `NestWeb.Auth.FetchCurrentUser`.

  Must be placed in the pipeline AFTER `FetchCurrentUser` —
  this plug only reads what that one set.

  For HTTP requests the body is a small JSON map with `error:
  "unauthenticated"`. Channel topics use Phoenix's own error
  contract — see `NestWeb.UserSocket` for the WebSocket
  equivalent.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "unauthenticated"}))
      |> halt()
    end
  end
end
