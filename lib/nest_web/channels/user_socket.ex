defmodule NestWeb.UserSocket do
  @moduledoc """
  Socket handler for WebSocket connections.

  Manages the initial WebSocket connection and dispatches to
  appropriate channels based on the topic.
  """

  use Phoenix.Socket

  require Logger

  # Channels
  channel "lobby", NestWeb.LobbyChannel
  channel "agent:*", NestWeb.AgentChannel

  @doc """
  Connects the socket with the given params.

  For now, accepts all connections without authentication.
  """
  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, assign(socket, :user_id, generate_user_id())}
  end

  @doc """
  Returns the socket ID for identifying the socket connection.
  """
  @impl true
  def id(socket), do: "users_socket:#{socket.assigns.user_id}"

  defp generate_user_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end
end
