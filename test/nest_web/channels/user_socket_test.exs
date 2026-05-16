defmodule NestWeb.UserSocketTest do
  @moduledoc """
  Tests for the UserSocket module.
  """
  use NestWeb.ChannelCase

  alias NestWeb.UserSocket

  describe "connect/3" do
    test "connects with valid params" do
      assert {:ok, socket} = UserSocket.connect(%{}, socket(NestWeb.UserSocket), nil)
      assert socket.transport_pid != nil
    end

    test "assigns user_id" do
      {:ok, socket} = UserSocket.connect(%{}, socket(NestWeb.UserSocket), nil)
      assert is_binary(socket.assigns.user_id)
      assert String.length(socket.assigns.user_id) > 0
    end
  end

  describe "id/1" do
    test "returns socket identifier" do
      socket = %Phoenix.Socket{assigns: %{user_id: "user-123"}}
      assert UserSocket.id(socket) == "users_socket:user-123"
    end
  end
end
