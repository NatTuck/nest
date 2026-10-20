defmodule NestWeb.UserSocketTest do
  @moduledoc """
  Tests for the UserSocket module.

  The socket requires a `token` in its connect params. Tests
  create a user, sign a token via `Nest.Accounts.AuthToken`,
  and verify both happy-path acceptance and rejection paths
  (missing token, malformed token).
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
    test "connects with a valid token and identifies as the user", %{user: user, token: token} do
      assert {:ok, socket} =
               UserSocket.connect(%{"token" => token}, socket(NestWeb.UserSocket), nil)

      assert socket.assigns.current_user.id == user.id
      assert UserSocket.id(socket) == "users_socket:#{user.id}"
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
  end
end
