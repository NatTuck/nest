defmodule Nest.Agents.SupervisorSpawnTest do
  @moduledoc """
  Tests for `Supervisor.spawn_agent_in_space/3` — the entry
  point that creates a fresh-context sub-agent in a space,
  authorized against the space's blueprint
  `spawnable_vocations` whitelist.

  `spawn_agent_in_space/3` requires a real parent agent (it
  reads `name`, `depth`, and resolves the parent's DB row for
  `parent_id`), so each test starts a real coordinator agent
  in the target space and passes its runtime state.

  ## What's covered

    * Unrestricted space (no blueprint) → any vocation spawns.
    * Whitelisted blueprint → allowed vocation spawns, denied
      vocation returns `{:error, {:vocation_not_spawnable, _}}`.
    * Omitted `vocation` → defaults to the parent's vocation,
      or auto-defaults to the sole allowed vocation, or is refused
      as ambiguous when multiple vocations are allowed.
    * Duplicate name → `{:error, :duplicate_name}` (the
      `(space_id, name)` composite unique index).
    * Fresh context → the spawned agent's message count is 1
      (system prompt only).
    * Fresh spawns get `depth = parent + 1`.
  """
  use Nest.DataCase, async: true

  import Eventually

  alias Nest.Agents
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Spaces
  alias Nest.Vocations

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id}
  end

  # Start a real coordinator agent in `space_id` and return
  # its runtime state. `spawn_agent_in_space/3` needs a real
  # parent (name + persisted row for `parent_id`).
  defp coordinator_state(space_id) do
    name = "coord-#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      Agents.create_agent(space_id, test_model(),
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    AgentTestHelpers.ensure_cleanup(name)

    {:ok, pid} = Supervisor.get_agent(space_id, name)
    :sys.get_state(pid, 500)
  end

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}

  defp agent_count(space_id) do
    Nest.Repo.one(from(a in "agents", where: a.space_id == ^space_id, select: count(a.id)))
  end

  defp message_count(space_id) do
    Nest.Repo.one(
      from(m in "messages",
        join: a in "agents",
        on: m.agent_id == a.id,
        where: a.space_id == ^space_id,
        select: count(m.id)
      )
    )
  end

  # Insert an agent row and archive it, returning the row. `parent_id`
  # and `depth` are what set the subtree shape: once the processes are
  # archived the `ChildRegistry` entries are gone, so the persisted
  # `parent_id` links are the only record of the tree.
  defp insert_archived_row(space_id, name, parent_id \\ nil, depth \\ 0) do
    {:ok, row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: test_model(),
        vocation_id: AgentTestHelpers.vocation_id_for_test(),
        parent_id: parent_id,
        depth: depth
      })

    assert :ok = Nest.Persistence.archive_agent(space_id, name)
    row
  end

  # Collect `count` `agent:unarchived` broadcasts for `space_id`, in the
  # order they arrived.
  defp unarchived_names(space_id, count) do
    for _ <- 1..count do
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent:unarchived",
                       payload: %{"space_id" => ^space_id, "name" => name}
                     },
                     1_000

      name
    end
  end

  defp fresh_vocation do
    {:ok, vocation} =
      Vocations.upsert_vocation(%{
        name: "SpawnVocation-#{System.unique_integer([:positive])}",
        description: "Spawn test",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    vocation
  end

  describe "spawn_agent_in_space/3 in an unrestricted space" do
    test "spawns an independent specialist with any vocation", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "specialist-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.vocation_id == vocation.id
    end

    test "spawned agent has fresh context (system prompt only)", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "fresh-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.message_count == 1
    end

    test "fresh spawn gets depth = parent.depth + 1", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "depth-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.depth == state.depth + 1
    end

    test "spawn with a model override gives the child the override model", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "model-override-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)
      override = %{name: "pegasus-default-only", provider: "pegasus"}

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(state, name, vocation.slug, override)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      child_state = :sys.get_state(pid, 500)
      assert child_state.model == override
    end

    test "spawn without a model override inherits the parent's model", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "inherit-model-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      child_state = :sys.get_state(pid, 500)
      assert child_state.model == state.model
    end

    test "fresh spawn at max depth has agents-spawn excluded from its tool list",
         %{space_id: space_id} do
      max = Config.configured_max_depth()
      vocation = fresh_vocation()
      name = "maxdepth-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)
      state = %{state | depth: max}

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      child_state = :sys.get_state(pid, 500)
      assert child_state.depth == max + 1
      refute Enum.any?(child_state.tools, &(&1.name == "agents-spawn"))
    end

    test "rejects a duplicate name in the space", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "dup-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      assert {:error, :duplicate_name} =
               Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
    end

    test "an unknown vocation slug is rejected" do
      name = "unknown-voc-#{System.unique_integer([:positive])}"
      state = coordinator_state(AgentTestHelpers.current_space_id())

      assert {:error, {:vocation_not_found, "does-not-exist"}} =
               Supervisor.spawn_agent_in_space(state, name, "does-not-exist")
    end
  end

  describe "spawn_agent_in_space/3 whitelist enforcement" do
    test "allows a whitelisted vocation and denies a non-whitelisted one" do
      allowed = fresh_vocation()
      denied = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "whitelist-#{System.unique_integer([:positive])}",
          root_vocation: allowed.slug,
          spawnable_vocations: [allowed.slug]
        })

      {:ok, space} =
        Spaces.create_space(nil, %{
          name: "whitelist-space-#{System.unique_integer([:positive])}",
          slug: "whitelist-space-#{System.unique_integer([:positive])}",
          blueprint_id: blueprint.id
        })

      state = coordinator_state(space.id)
      allowed_name = "allowed-#{System.unique_integer([:positive])}"
      denied_name = "denied-#{System.unique_integer([:positive])}"

      assert {:ok, ^allowed_name} =
               Supervisor.spawn_agent_in_space(state, allowed_name, allowed.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, allowed_name) end)

      # The refusal carries the whitelisted vocations as {name, slug}
      # labels so the caller can tell the model what it may spawn.
      assert {:error, {:vocation_not_spawnable, [{_name, allowed_slug}]}} =
               Supervisor.spawn_agent_in_space(state, denied_name, denied.slug)

      assert allowed_slug == allowed.slug
      refute Enum.member?(Agents.list_agents_for_space(space.id), denied_name)
    end

    test "omitting vocation auto-defaults to the sole allowed vocation" do
      allowed = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "auto-wl-#{System.unique_integer([:positive])}",
          root_vocation: allowed.slug,
          spawnable_vocations: [allowed.slug]
        })

      {:ok, space} =
        Spaces.create_space(nil, %{
          name: "auto-wl-space-#{System.unique_integer([:positive])}",
          slug: "auto-wl-space-#{System.unique_integer([:positive])}",
          blueprint_id: blueprint.id
        })

      # The coordinator's own vocation (Test Default) is NOT in the
      # whitelist — exactly the "Head TA may only spawn Graders" shape.
      state = coordinator_state(space.id)
      refute state.vocation_id == allowed.id

      name = "auto-#{System.unique_integer([:positive])}"

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)

      {:ok, pid} = Supervisor.get_agent(space.id, name)
      child_state = :sys.get_state(pid, 500)
      assert child_state.vocation_id == allowed.id
    end

    test "omitting vocation with multiple allowed vocations is refused as ambiguous" do
      allowed_a = fresh_vocation()
      allowed_b = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "ambig-wl-#{System.unique_integer([:positive])}",
          root_vocation: allowed_a.slug,
          spawnable_vocations: [allowed_a.slug, allowed_b.slug]
        })

      {:ok, space} =
        Spaces.create_space(nil, %{
          name: "ambig-wl-space-#{System.unique_integer([:positive])}",
          slug: "ambig-wl-space-#{System.unique_integer([:positive])}",
          blueprint_id: blueprint.id
        })

      state = coordinator_state(space.id)
      name = "ambig-#{System.unique_integer([:positive])}"

      assert {:error, {:vocation_not_spawnable, labels}} =
               Supervisor.spawn_agent_in_space(state, name)

      slugs = Enum.map(labels, &elem(&1, 1))
      assert Enum.sort(slugs) == Enum.sort([allowed_a.slug, allowed_b.slug])
    end

    test "an empty spawnable_vocations list is unrestricted" do
      vocation = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "empty-wl-#{System.unique_integer([:positive])}",
          root_vocation: vocation.slug,
          spawnable_vocations: []
        })

      {:ok, space} =
        Spaces.create_space(nil, %{
          name: "empty-wl-space-#{System.unique_integer([:positive])}",
          slug: "empty-wl-space-#{System.unique_integer([:positive])}",
          blueprint_id: blueprint.id
        })

      name = "any-#{System.unique_integer([:positive])}"
      state = coordinator_state(space.id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)
    end
  end

  describe "a failed spawn" do
    test "leaves no orphan row, so the same name can be spawned again", %{space_id: space_id} do
      state = coordinator_state(space_id)
      name = "spawn-rollback-#{System.unique_integer([:positive])}"
      space_dir = TmpSpace.space_dir(space_id)

      # Make the child's `init/1` fail deterministically: `TmpSpace.create/2`
      # does `File.mkdir_p!` on the child's own scratch dir, so a *file*
      # where that directory belongs raises `File.Error` during the start.
      File.mkdir_p!(space_dir)
      blocker = Path.join(space_dir, name)
      File.write!(blocker, "not a directory")

      on_exit(fn -> File.rm(blocker) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _reason} = Supervisor.spawn_agent_in_space(state, name)
        end)

      # The row the spawn pre-spawned is gone (and its system message with
      # it), so the space holds only the coordinator — and the name is free
      # again rather than blocked by an orphan.
      assert Nest.Persistence.fetch_agent(space_id, name) == {:error, :not_found}
      assert agent_count(space_id) == 1
      assert message_count(space_id) == 1
      assert log =~ "failed to start"

      File.rm!(blocker)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name)
      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, _row} = Nest.Persistence.fetch_agent(space_id, name)
      assert agent_count(space_id) == 2
    end
  end

  describe "archive_agent/2" do
    test "stops the process, marks the row archived, and broadcasts agent:archived", %{
      space_id: space_id
    } do
      vocation = fresh_vocation()
      name = "archive-me-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space_id))

      assert :ok = Supervisor.archive_agent(space_id, name)

      assert_receive {:agent_archived, %{"space_id" => ^space_id, "name" => ^name}},
                     1_000

      assert eventually(
               fn ->
                 Nest.Agents.Registry.lookup(space_id, name) == {:error, :not_found}
               end,
               timeout: 1_000
             )

      {:ok, row} = Nest.Persistence.fetch_agent(space_id, name)
      assert row.archived == true
    end
  end

  describe "unarchive_agent/2" do
    test "flips the archived flag back and broadcasts agent:unarchived", %{space_id: space_id} do
      name = "unarchive-me-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: test_model(),
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        })

      assert :ok = Nest.Persistence.archive_agent(space_id, name)

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, name)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent:unarchived",
                       payload: %{"space_id" => ^space_id, "name" => ^name}
                     },
                     1_000

      {:ok, row} = Nest.Persistence.fetch_agent(space_id, name)
      assert row.archived == false
    end

    test "returns not_found for a missing agent", %{space_id: space_id} do
      name = "ghost-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = Supervisor.unarchive_agent(space_id, name)
    end

    test "restores a parent together with its archived children", %{space_id: space_id} do
      suffix = System.unique_integer([:positive])
      parent = "subtree-parent-#{suffix}"
      child_a = "subtree-child-a-#{suffix}"
      child_b = "subtree-child-b-#{suffix}"

      parent_row = insert_archived_row(space_id, parent)
      _child_a_row = insert_archived_row(space_id, child_a, parent_row.id, 1)
      _child_b_row = insert_archived_row(space_id, child_b, parent_row.id, 1)

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, parent)

      # One broadcast per restored row, in name order (the subtree walk
      # is sorted, not map-ordered), and none for anything outside it.
      assert unarchived_names(space_id, 3) ==
               Enum.sort([parent, child_a, child_b])

      for name <- [parent, child_a, child_b] do
        assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, name)
      end
    end

    test "restores a deep chain, not just the immediate children", %{space_id: space_id} do
      suffix = System.unique_integer([:positive])
      root = "chain-root-#{suffix}"
      middle = "chain-middle-#{suffix}"
      leaf = "chain-leaf-#{suffix}"

      root_row = insert_archived_row(space_id, root)
      middle_row = insert_archived_row(space_id, middle, root_row.id, 1)
      _leaf_row = insert_archived_row(space_id, leaf, middle_row.id, 2)

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, root)

      assert unarchived_names(space_id, 3) == Enum.sort([root, middle, leaf])

      for name <- [root, middle, leaf] do
        assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, name)
      end
    end

    test "is a no-op for an agent that is already active", %{space_id: space_id} do
      name = "already-active-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: test_model(),
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, name)

      # Nothing changed, so nothing is broadcast: the restore is
      # synchronous, so a broadcast would already be in the mailbox.
      refute_received %Phoenix.Socket.Broadcast{
        event: "agent:unarchived",
        payload: %{"space_id" => ^space_id, "name" => ^name}
      }

      assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, name)
    end

    test "refuses a child whose parent is still archived, naming the parent", %{
      space_id: space_id
    } do
      suffix = System.unique_integer([:positive])
      parent = "blocked-parent-#{suffix}"
      child = "blocked-child-#{suffix}"

      parent_row = insert_archived_row(space_id, parent)
      _child_row = insert_archived_row(space_id, child, parent_row.id, 1)

      assert {:error, {:parent_archived, ^parent}} =
               Supervisor.unarchive_agent(space_id, child)

      # The refusal leaves both rows alone rather than half-restoring.
      for name <- [parent, child] do
        assert {:ok, %{archived: true}} = Nest.Persistence.fetch_agent(space_id, name)
      end

      # Restoring the parent is the way through, and it brings the
      # child back with it.
      assert :ok = Supervisor.unarchive_agent(space_id, parent)
      assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, child)
    end
  end

  describe "spawn workspace validation" do
    test "rejects a child whose inherited workspace is under /tmp", %{space_id: space_id} do
      {:ok, vocation} =
        Vocations.upsert_vocation(%{
          name: "WSSpawn-#{System.unique_integer([:positive])}",
          description: "needs a workspace",
          system_prompt: "ws",
          tools: [],
          modes: %{
            "build" => %{
              "description" => "writes workspace",
              "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => [":workspace"]}}
            }
          }
        })

      name = "ws-child-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      # The parent inherited a /tmp-rooted workspace; a child that needs one
      # must not start against it.
      state = %{state | workspace_path: "/tmp/ws"}

      assert {:error, :workspace_under_tmp} =
               Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      # A parent with no workspace and a workspace-requiring child is the
      # pre-existing `:workspace_required` case.
      assert {:error, :workspace_required} =
               Supervisor.spawn_agent_in_space(
                 %{state | workspace_path: nil},
                 name,
                 vocation.slug
               )
    end
  end
end
