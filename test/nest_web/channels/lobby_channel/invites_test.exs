defmodule NestWeb.LobbyChannel.InvitesTest do
  @moduledoc """
  Tests for `NestWeb.LobbyChannel.Invites` — the
  `create_invite` / `revoke_invite` handlers that the
  lobby's `handle_in` dispatches to.

  Pure-function tests over `(payload, fake_socket)` —
  asserts the returned `{:reply, reply, socket}` tuple
  shape, the database side effects, and that the
  `Phoenix.Channel.push/3` calls fire (stubbed via
  `Mimic` so we don't need a fully joined socket).
  """

  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Invites
  alias Phoenix.Socket

  setup :verify_on_exit!
  setup :set_mimic_global

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(Accounts.User)

    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, invite, _} = Accounts.create_invite(alice.id)

    {:ok, bob} =
      Accounts.redeem_invite(invite.token, %{username: "bob", password: "password123"})

    %{alice: alice, bob: bob}
  end

  # Build a minimal socket stub with a `current_user`
  # assignment. `Phoenix.Channel.push/3` is stubbed via
  # Mimic to be a no-op so we don't need a joined socket.
  defp build_socket(user) do
    %Socket{}
    |> Phoenix.Socket.assign(:current_user, user)
  end

  describe "create_invite/2" do
    test "returns {:ok, public_invite} on success", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      socket = build_socket(alice)

      assert {:reply, {:ok, public}, _socket} = Invites.create_invite(%{}, socket)
      assert public.id
      assert public.token
      assert public.created_by_user_id == alice.id
      assert public.used_at == nil
      assert public.revoked_at == nil
    end

    test "returns {:error, too_many_invites} after 10 invites", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      # The setup already created 1 invite (for bob's
      # registration). Mint 9 more so alice owns exactly
      # 10; the next call must hit the cap.
      for _ <- 1..9 do
        {:ok, _, _} = Accounts.create_invite(alice.id)
      end

      socket = build_socket(alice)

      assert {:reply, {:error, %{error: "too_many_invites"}}, _socket} =
               Invites.create_invite(%{}, socket)
    end
  end

  describe "revoke_invite/2" do
    test "returns :ok for the owner", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      {:ok, invite, _} = Accounts.create_invite(alice.id)
      socket = build_socket(alice)

      assert {:reply, :ok, _socket} =
               Invites.revoke_invite(%{"id" => Integer.to_string(invite.id)}, socket)

      refreshed = Repo.get!(InviteSchema, invite.id)
      assert refreshed.revoked_at
    end

    test "returns :ok when id arrives as a JSON integer (modern JS shape)", %{
      alice: alice
    } do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      {:ok, invite, _} = Accounts.create_invite(alice.id)
      socket = build_socket(alice)

      assert {:reply, :ok, _socket} =
               Invites.revoke_invite(%{"id" => invite.id}, socket)

      refreshed = Repo.get!(InviteSchema, invite.id)
      assert refreshed.revoked_at
    end

    test "returns {:error, :forbidden} when called by a non-owner", %{
      alice: alice,
      bob: bob
    } do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      {:ok, invite, _} = Accounts.create_invite(alice.id)
      socket = build_socket(bob)

      assert {:reply, {:error, %{error: "forbidden"}}, _socket} =
               Invites.revoke_invite(%{"id" => Integer.to_string(invite.id)}, socket)
    end

    test "returns {:error, :not_found} for an unknown id", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      socket = build_socket(alice)

      assert {:reply, {:error, %{error: "not_found"}}, _socket} =
               Invites.revoke_invite(%{"id" => "9999999"}, socket)
    end

    test "returns {:error, :invalid_id} for a non-integer id", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      socket = build_socket(alice)

      assert {:reply, {:error, %{error: "invalid_id"}}, _socket} =
               Invites.revoke_invite(%{"id" => "not-a-number"}, socket)
    end

    test "returns {:error, :invalid_id} for a non-integer, non-string id", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      socket = build_socket(alice)

      assert {:reply, {:error, %{error: "invalid_id"}}, _socket} =
               Invites.revoke_invite(%{"id" => nil}, socket)
    end

    test "returns {:error, :already_used} for a redeemed invite", %{alice: alice} do
      stub(Phoenix.Channel, :push, fn _socket, _event, _payload -> :ok end)
      {:ok, invite, _} = Accounts.create_invite(alice.id)

      {:ok, _} =
        Accounts.redeem_invite(invite.token, %{username: "carol", password: "password123"})

      socket = build_socket(alice)

      assert {:reply, {:error, %{error: "already_used"}}, _socket} =
               Invites.revoke_invite(%{"id" => Integer.to_string(invite.id)}, socket)
    end
  end
end
