defmodule Nest.Agents.VisibilityTest do
  @moduledoc """
  Branch coverage for `Nest.Agents.Visibility`.

  The lobby's `:after_join` exercises the happy path (own
  agent + not-alive agent) — these tests target the
  remaining branches: a shared agent visible to a
  non-owner, and an agent whose pid can't be looked up.

  Each test runs in its own freshly created space and its own
  sandbox transaction, so they can run concurrently.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents
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

  test "an archived agent is filtered out of the persisted backfill" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {_pid, name} =
      AgentTestHelpers.start_agent(%{
        name: "archived-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      })

    # Archive: stop the process + mark the DB row archived.
    # The persisted-backfill path in `Visibility` would otherwise
    # surface the row even though the pid is down. Trap exits so
    # the linked agent's stop doesn't kill the test pid.
    Process.flag(:trap_exit, true)
    :ok = Supervisor.archive_agent(AgentTestHelpers.current_space_id(), name)
    assert_receive {:EXIT, _, _}, 500

    visible = Visibility.list_visible_agents_for(AgentTestHelpers.current_space_id(), alice.id)
    assert Enum.all?(visible, &(&1.name != name))
  end

  test "list_non_archived_agents_for_space/1 lists running and persisted-only agents, excluding archived" do
    # The merged, no-user-filter listing behind `agents-list`.
    model = %{name: "qwen3.5-plus", provider: "model-studio"}

    {_pid, running_name} =
      AgentTestHelpers.start_agent(%{
        name: "running-#{System.unique_integer([:positive])}",
        model: model
      })

    space_id = AgentTestHelpers.current_space_id()

    # A second agent in the same space, stopped so only its
    # non-archived DB row remains. The merged listing must backfill
    # it even though the registry has no live pid for it.
    stopped_name = "stopped-#{System.unique_integer([:positive])}"

    {:ok, ^stopped_name} =
      Agents.create_agent(space_id, model,
        name: stopped_name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    AgentTestHelpers.ensure_cleanup(stopped_name)
    Supervisor.stop_agent(space_id, stopped_name)
    AgentTestHelpers.wait_for_pid_down(space_id, stopped_name)

    # An archived row must never appear.
    archived_name = "archived-#{System.unique_integer([:positive])}"

    {:ok, _row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: archived_name,
        model: model,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      })

    assert :ok = Nest.Persistence.archive_agent(space_id, archived_name)

    infos = Visibility.list_non_archived_agents_for_space(space_id)
    names = Enum.map(infos, & &1.name)

    # The running agent's registry entry and its DB row de-dupe to
    # one entry.
    assert Enum.count(names, &(&1 == running_name)) == 1
    assert stopped_name in names
    refute archived_name in names

    # Both branches report the agent's vocation slug: the registry
    # branch from the live agent's vocation struct, the persisted-only
    # branch resolved from the row's `vocation_id`. Both agents here
    # were created with the per-test default vocation.
    slug = AgentTestHelpers.vocation_slug_for_test()
    assert Enum.find(infos, &(&1.name == running_name)).vocation_slug == slug
    assert Enum.find(infos, &(&1.name == stopped_name)).vocation_slug == slug
  end

  test "list_non_archived_agents_for_space/1 orders persisted-only agents by name" do
    # The `agents-list` tool truncates its serialized result to 4000 chars,
    # so the persisted backfill is ordered by name: the dropped tail is
    # always the alphabetically-last agents, not a query-order accident.
    space_id = AgentTestHelpers.current_space_id()
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    vid = AgentTestHelpers.vocation_id_for_test()

    # Insert out of alphabetical order so insertion order can't
    # accidentally satisfy the assertion. These are persisted-only
    # (no live pid), so the registry branch contributes nothing.
    for name <- ["zeta", "alpha", "mu"] do
      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: model,
          vocation_id: vid
        })
    end

    names = Visibility.list_non_archived_agents_for_space(space_id) |> Enum.map(& &1.name)
    assert names == ["alpha", "mu", "zeta"]
  end

  test "list_non_archived_agents_for_space/1 orders a mixed live + persisted list by name" do
    # The registry (live) branch is concatenated ahead of the persisted
    # branch, so name-ordering has to be applied to the *merged* list:
    # otherwise a live agent would always lead the listing and the
    # `agents-list` truncation tail would depend on which branch an
    # agent came from. The running agent here sorts last, so an
    # unsorted merge would put it first.
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    suffix = System.unique_integer([:positive])
    running_name = "zulu-#{suffix}"

    {_pid, ^running_name} = AgentTestHelpers.start_agent(%{name: running_name, model: model})

    space_id = AgentTestHelpers.current_space_id()
    vid = AgentTestHelpers.vocation_id_for_test()

    # Persisted-only (no live pid) rows, inserted out of order.
    for name <- ["mu-#{suffix}", "alpha-#{suffix}"] do
      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: model,
          vocation_id: vid
        })
    end

    names = Visibility.list_non_archived_agents_for_space(space_id) |> Enum.map(& &1.name)

    assert names == ["alpha-#{suffix}", "mu-#{suffix}", running_name]
  end

  test "list_archived_agents_for/2 returns archived rows with resolved parent_name" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, _invite, token} = Accounts.create_invite(alice.id)

    {:ok, bob} =
      Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

    space_id = AgentTestHelpers.current_space_id()
    suffix = System.unique_integer([:positive])
    parent_name = "arch-parent-#{suffix}"
    child_name = "arch-child-#{suffix}"
    shared_name = "arch-shared-#{suffix}"
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    vid = AgentTestHelpers.vocation_id_for_test()

    {:ok, parent_row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: parent_name,
        model: model,
        vocation_id: vid,
        created_by_user_id: alice.id,
        shared: false
      })

    {:ok, _child_row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: child_name,
        model: model,
        vocation_id: vid,
        parent_id: parent_row.id,
        depth: 1,
        created_by_user_id: alice.id,
        shared: false
      })

    {:ok, _shared_row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: shared_name,
        model: model,
        vocation_id: vid,
        created_by_user_id: alice.id,
        shared: true
      })

    for name <- [parent_name, child_name, shared_name] do
      assert :ok = Nest.Persistence.archive_agent(space_id, name)
    end

    archived = Visibility.list_archived_agents_for(space_id, alice.id)

    child = Enum.find(archived, &(&1.name == child_name))
    assert child.archived == true
    assert child.depth == 1
    assert child.parent_name == parent_name

    # A private archived agent is invisible to a non-owner; a shared
    # one is visible.
    bob_names =
      Visibility.list_archived_agents_for(space_id, bob.id) |> Enum.map(& &1.name)

    refute child_name in bob_names
    assert shared_name in bob_names
  end
end
