defmodule Nest.Agents.VisibilityTest do
  @moduledoc """
  Branch coverage for `Nest.Agents.Visibility`.

  The lobby's `:after_join` exercises the happy path (own
  agent + not-alive agent) — these tests target the
  remaining branches: a shared agent visible to a
  non-owner, and an agent whose pid can't be looked up.
  """

  use Nest.DataCase, async: false

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Agents.Visibility
  alias Nest.Repo

  alias Nest.Accounts
  alias Nest.Accounts.Invite, as: InviteSchema
  alias Nest.Accounts.User, as: UserSchema

  setup do
    Repo.delete_all(InviteSchema)
    Repo.delete_all(UserSchema)

    {:ok, _space_id} = AgentTestHelpers.create_test_space()

    for name <- Nest.Persistence.list_agent_names_for_space(AgentTestHelpers.current_space_id()) do
      Supervisor.stop_agent(AgentTestHelpers.current_space_id(), name)
      Nest.Persistence.delete_agent(AgentTestHelpers.current_space_id(), name)
    end

    :ok
  end

  test "shared agent is visible to a non-owner" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, _invite, token} = Accounts.create_invite(alice.id)

    {:ok, bob} =
      Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

    {_pid, name} =
      AgentTestHelpers.start_agent(%{
        name: "shared-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        created_by_user_id: alice.id,
        shared: true
      })

    visible_ids =
      Visibility.list_visible_agents_for(AgentTestHelpers.current_space_id(), bob.id)
      |> Enum.map(& &1.name)

    assert name in visible_ids
  end

  test "private agent is NOT visible to a non-owner" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, _invite, token} = Accounts.create_invite(alice.id)

    {:ok, bob} =
      Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

    {_pid, name} =
      AgentTestHelpers.start_agent(%{
        name: "private-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        created_by_user_id: alice.id,
        shared: false
      })

    visible_ids =
      Visibility.list_visible_agents_for(AgentTestHelpers.current_space_id(), bob.id)
      |> Enum.map(& &1.name)

    refute name in visible_ids
  end

  test "own private agent is visible to its owner" do
    # Branches the OR short-circuits: when
    # `created_by_user_id == user_id` is true, the right side
    # of the OR (`info.shared == true`) is never evaluated.
    # This test exercises that path with `shared: false` so
    # both branches of the OR are tested across the suite.
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {_pid, name} =
      AgentTestHelpers.start_agent(%{
        name: "private-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        created_by_user_id: alice.id,
        shared: false
      })

    visible_ids =
      Visibility.list_visible_agents_for(AgentTestHelpers.current_space_id(), alice.id)
      |> Enum.map(& &1.name)

    assert name in visible_ids
  end

  test "an agent whose pid is dead is filtered out" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {_pid, name} =
      AgentTestHelpers.start_agent(%{
        name: "dead-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      })

    # Terminate the agent so the registry lookup fails.
    # Trap exits so the agent's :EXIT doesn't kill the test
    # pid (the agent was started linked via `start_agent/1`).
    Process.flag(:trap_exit, true)
    Supervisor.stop_agent(AgentTestHelpers.current_space_id(), name)
    assert_receive {:EXIT, _, _}, 500

    visible = Visibility.list_visible_agents_for(AgentTestHelpers.current_space_id(), alice.id)
    assert Enum.all?(visible, &(&1.name != name))
  end
end
