defmodule NestWeb.UserSocket do
  @moduledoc """
  Socket handler for WebSocket connections.

  Manages the initial WebSocket connection and dispatches to
  appropriate channels based on the topic.

  ## Authentication

  `connect/3` requires a `token` in the socket params (sent
  by the client from `localStorage`). The token is verified
  via `Nest.Accounts.get_user_by_token/1`; valid tokens
  populate `socket.assigns.current_user`, invalid or missing
  tokens cause the connection to be rejected with
  `:error`. Downstream channels (`lobby`, `agent:*`) read
  `:current_user` to enforce ownership and visibility rules.
  """

  use Phoenix.Socket

  require Logger

  alias Nest.Accounts

  # Channels
  channel "lobby", NestWeb.LobbyChannel
  channel "agent:*", NestWeb.AgentChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info)
      when is_binary(token) and byte_size(token) > 0 do
    case Accounts.get_user_by_token(token) do
      %Accounts.User{} = user ->
        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:user_id, user.id)

        {:ok, socket}

      nil ->
        Logger.warning("UserSocket: rejecting connection — invalid token")
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    Logger.warning("UserSocket: rejecting connection — missing token")
    :error
  end

  @doc """
  Returns the socket ID for identifying the socket connection.
  """
  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.user_id}"
end
