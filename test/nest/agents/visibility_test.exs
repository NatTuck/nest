defmodule Nest.Agents.VisibilityTest do
  @moduledoc """
  Branch coverage for `Nest.Agents.Visibility`.

  The lobby's `:after_join` only checks that its `agents` payload is a
  list, so the per-user rules themselves are pinned here: an owner sees
  their own private agent, and everyone sees a shared one.

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

  test "list_visible_agents_for/2 shows an owner their private agent, a non-owner only the shared one" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    {:ok, _invite, token} = Accounts.create_invite(alice.id)

    {:ok, bob} =
      Accounts.redeem_invite(token, %{username: "bob", password: "password456"})

    model = %{name: "qwen3.5-plus", provider: "model-studio"}

    {_pid, private_name} =
      AgentTestHelpers.start_agent(%{
        name: "private-#{System.unique_integer([:positive])}",
        model: model,
        created_by_user_id: alice.id,
        shared: false
      })

    # `start_agent/1` creates a fresh space per call, so the second agent is
    # created directly to land it in the *same* space as the first.
    space_id = AgentTestHelpers.current_space_id()
    shared_name = "shared-#{System.unique_integer([:positive])}"

    {:ok, ^shared_name} =
      Agents.create_agent(space_id, model,
        name: shared_name,
        vocation_id: AgentTestHelpers.vocation_id_for_test(),
        created_by_user_id: alice.id,
        shared: true
      )

    AgentTestHelpers.ensure_cleanup(shared_name)

    alice_names =
      Visibility.list_visible_agents_for(space_id, alice.id) |> Enum.map(& &1.name)

    bob_names = Visibility.list_visible_agents_for(space_id, bob.id) |> Enum.map(& &1.name)

    # `created_by_user_id == user_id` (the short-circuiting left side of the
    # OR), `shared == false` for a non-owner, and `shared == true`.
    assert private_name in alice_names
    refute private_name in bob_names
    assert shared_name in bob_names
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
    # The tight detector bound (the `wait_for_pid_down/2` default): this is a
    # body fence — the listing below is only meaningful once the stopped agent
    # is gone — not cleanup, so it does not want the generous cleanup bound.
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

    names =
      Visibility.list_non_archived_agents_for_space(space_id) |> Enum.map(& &1.name)

    # The running agent's registry entry and its DB row de-dupe to
    # one entry.
    assert Enum.count(names, &(&1 == running_name)) == 1
    assert stopped_name in names
    refute archived_name in names
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
    assert child.depth == 1
    assert child.parent_name == parent_name

    # A private archived agent is invisible to a non-owner; a shared
    # one is visible.
    bob_names =
      Visibility.list_archived_agents_for(space_id, bob.id) |> Enum.map(& &1.name)

    refute child_name in bob_names
    assert shared_name in bob_names
  end

  test "list_archived_agents_for_space/1 returns every archived row, no user filter" do
    {:ok, alice, :admin} =
      Accounts.create_user(%{username: "alice", password: "password123"}, "first-user")

    space_id = AgentTestHelpers.current_space_id()
    suffix = System.unique_integer([:positive])
    private_name = "arch-space-private-#{suffix}"
    active_name = "arch-space-active-#{suffix}"
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    vid = AgentTestHelpers.vocation_id_for_test()

    {:ok, _private_row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: private_name,
        model: model,
        vocation_id: vid,
        created_by_user_id: alice.id,
        shared: false
      })

    assert :ok = Nest.Persistence.archive_agent(space_id, private_name)

    {:ok, _active_row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: active_name,
        model: model,
        vocation_id: vid,
        created_by_user_id: alice.id,
        shared: false
      })

    archived = Visibility.list_archived_agents_for_space(space_id)

    # The space-scoped read carries no user identity: even a
    # private (non-shared) archived row is listed, and the
    # non-archived row is not.
    assert [%{name: ^private_name, archived: true}] = archived
  end
end
