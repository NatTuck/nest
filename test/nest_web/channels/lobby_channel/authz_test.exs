defmodule NestWeb.LobbyChannel.AuthzTest do
  @moduledoc """
  Branch coverage for `NestWeb.LobbyChannel.Authz`. The
  LobbyChannel integration tests cover the happy path
  (owner edits, shared agent edit-rejection); these target
  the remaining branches: non-owner rejects on private
  agents, the persisted-row fallback when the supervisor's
  pid is dead, and the not-found path.
  """

  use Nest.DataCase, async: true

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Repo
  alias NestWeb.LobbyChannel.Authz

  import Mimic

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, space_id} = AgentTestHelpers.create_test_space()

    # Drain leftover agents so the Registry lookup test
    # paths behave deterministically.
    for name <- Persistence.list_agent_names_for_space(space_id) do
      Supervisor.stop_agent(space_id, name)
      Persistence.delete_agent(space_id, name)
    end

    :ok
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

      assert Authz.authorize_owner_or_shared(AgentTestHelpers.current_space_id(), name, bob) ==
               {:error, :forbidden}
    end

    test "returns :not_found when the row lookup itself misses" do
      assert Authz.authorize_owner_or_shared(
               AgentTestHelpers.current_space_id(),
               "definitely-not-a-real-agent",
               %{id: 1}
             ) == {:error, :not_found}
    end

    # The `catch :exit` arm in `fetch_visibility/2`: the registry names a pid
    # that is already dead, so the call into it exits and the persisted row
    # answers instead. That is a real production race — the agent can die
    # between `Registry.lookup/2` and `get_public_info/2` — so the arm must
    # stay. Reaching it by letting a real agent die is a race the suite would
    # win only sometimes, which is why this file's coverage of the line moved
    # with the seed; stubbing the call is the deterministic way to stand in
    # the same place.
    test "falls back to the persisted row when the registered pid is already dead" do
      {:ok, alice, :admin} =
        Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

      {_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          created_by_user_id: alice.id,
          shared: false
        })

      space_id = AgentTestHelpers.current_space_id()

      # The arm is only reachable through a *hit* on the registry, so assert
      # the setup really is the shape the test claims. Without this the test
      # would still pass if the lookup missed, having covered the other
      # fallback instead — the same mistake as a vacuous assertion.
      assert {:ok, _pid} = Nest.Agents.Registry.lookup(space_id, name)

      stub(Nest.Agents.Agent, :get_public_info, fn _pid -> exit(:noproc) end)

      # Same answer as a live agent gives: the fallback is transparent, which
      # is the property the caller depends on.
      assert {:ok, :owner} = Authz.authorize_owner_or_shared(space_id, name, alice)
    end
  end
end
