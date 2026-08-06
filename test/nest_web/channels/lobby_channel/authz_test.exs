defmodule NestWeb.LobbyChannel.AuthzTest do
  @moduledoc """
  Branch coverage for `NestWeb.LobbyChannel.Authz`. The
  LobbyChannel integration tests cover the happy path
  (owner edits, shared agent edit-rejection); these target
  the remaining branches: non-owner rejects on private
  agents, the persisted-row fallback when the supervisor's
  pid is dead, and the not-found path.
  """

  use Nest.DataCase, async: false

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Authz

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    # Drain leftover agents so the Registry lookup test
    # paths behave deterministically.
    for name <- Persistence.list_agent_names() do
      Supervisor.stop_agent(name)
      Persistence.delete_agent_by_name(name)
    end

    :ok
  end

  describe "authorize_owner/2" do
    test "returns :ok for the owner of a live agent" do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      {_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          created_by_user_id: alice.id
        })

      assert Authz.authorize_owner(name, alice) == :ok
      assert Authz.authorize_owner(name, bob) == {:error, :forbidden}
    end

    test "returns :forbidden on a private agent whose owner has no live pid" do
      # Persisted row fallback path: row exists, supervisor
      # doesn't have a pid, caller is not the owner.
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      {pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          created_by_user_id: alice.id
        })

      Process.flag(:trap_exit, true)
      Supervisor.stop_agent(name)
      assert_receive {:EXIT, ^pid, _}, 1000

      assert Authz.authorize_owner(name, bob) == {:error, :forbidden}
    end

    test "returns :not_found for an unknown agent name" do
      assert Authz.authorize_owner("nope-not-here", %{id: 999}) ==
               {:error, :not_found}
    end
  end

  describe "authorize_owner_or_shared/2" do
    test "returns :forbidden for a non-owner non-shared agent" do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {:ok, _invite, token} = Accounts.create_invite(alice.id)
      {:ok, bob} = Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

      {_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          created_by_user_id: alice.id,
          shared: false
        })

      assert Authz.authorize_owner_or_shared(name, bob) == {:error, :forbidden}
    end

    test "returns :not_found when the row lookup itself misses" do
      assert Authz.authorize_owner_or_shared("definitely-not-a-real-agent", %{id: 1}) ==
               {:error, :not_found}
    end
  end
end
