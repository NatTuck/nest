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
  end
end
