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
  alias Nest.Agents.Agent.Config
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
    :sys.get_state(pid)
  end

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}

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
      child_state = :sys.get_state(pid)
      assert child_state.model == override
    end

    test "spawn without a model override inherits the parent's model", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "inherit-model-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      child_state = :sys.get_state(pid)
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
      child_state = :sys.get_state(pid)
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
      child_state = :sys.get_state(pid)
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

  describe "archive_agent/2" do
    test "stops the process, marks the row archived, and broadcasts agent:archived", %{
      space_id: space_id
    } do
      vocation = fresh_vocation()
      name = "archive-me-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.archive_agent(space_id, name)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent:archived",
                       payload: %{"space_id" => ^space_id, "name" => ^name}
                     },
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
