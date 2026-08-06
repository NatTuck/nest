defmodule NestWeb.UserSocketTest do
  @moduledoc """
  Tests for the UserSocket module.

  The socket requires a `token` in its connect params. Tests
  create a user, sign a token via `Nest.Accounts.AuthToken`,
  and verify both happy-path acceptance and rejection paths
  (missing token, malformed token, valid token pointing at
  a non-existent user).
  """
  use NestWeb.ChannelCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.Repo
  alias NestWeb.UserSocket

  setup do
    Repo.delete_all(Accounts.Invite)
    Repo.delete_all(Accounts.User)

    {:ok, user, _role} =
      Accounts.create_user(%{username: "socket-tester", password: "password123"}, "first-user")

    {:ok, user: user, token: AuthToken.sign(user.id)}
  end

  describe "connect/3" do
    test "connects with a valid token", %{user: user, token: token} do
      assert {:ok, socket} =
               UserSocket.connect(%{"token" => token}, socket(NestWeb.UserSocket), nil)

      assert socket.assigns.current_user.id == user.id
      assert socket.assigns.user_id == user.id
    end

    test "rejects when the token is missing" do
      log =
        capture_log(fn ->
          assert :error = UserSocket.connect(%{}, socket(NestWeb.UserSocket), nil)
        end)

      assert log =~ "UserSocket: rejecting connection — missing token"
    end

    test "rejects when the token is malformed" do
      log =
        capture_log(fn ->
          assert :error =
                   UserSocket.connect(
                     %{"token" => "not-a-token"},
                     socket(NestWeb.UserSocket),
                     nil
                   )
        end)

      assert log =~ "UserSocket: rejecting connection — invalid token"
    end

    test "rejects a valid token whose user has been deleted", %{token: token} do
      # The token encodes a user_id; deleting that user
      # must invalidate the connection even though the
      # token itself is otherwise well-formed.
      Repo.delete_all(Accounts.User)

      log =
        capture_log(fn ->
          assert :error = UserSocket.connect(%{"token" => token}, socket(NestWeb.UserSocket), nil)
        end)

      assert log =~ "UserSocket: rejecting connection — invalid token"
    end
  end

  describe "id/1" do
    test "returns socket identifier" do
      socket = %Phoenix.Socket{assigns: %{user_id: 42}}
      assert UserSocket.id(socket) == "users_socket:42"
    end
  end
end
