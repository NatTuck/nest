defmodule Nest.Agents.SupervisorSpawnTest do
  @moduledoc """
  Tests for `Supervisor.spawn_agent_in_space/3` — the entry
  point that creates a fresh-context sub-agent in a space,
  authorized against the space's blueprint
  `spawnable_vocation_ids` whitelist.

  `spawn_agent_in_space/3` requires a real parent agent (it
  reads `name`, `depth`, and resolves the parent's DB row for
  `parent_id`), so each test starts a real coordinator agent
  in the target space and passes its runtime state.

  ## What's covered

    * Unrestricted space (no blueprint) → any vocation spawns.
    * Whitelisted blueprint → allowed vocation spawns, denied
      vocation returns `{:error, :vocation_not_spawnable}`.
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
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SpawnVocation-#{System.unique_integer([:positive])}",
        description: "Spawn test",
        system_prompt: "You are a specialist.",
        tools: ["context-check", "context-compact"],
        modes: %{}
      })

    vid
  end

  describe "spawn_agent_in_space/3 in an unrestricted space" do
    test "spawns an independent specialist with any vocation", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "specialist-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.vocation_id == vid
    end

    test "spawned agent has fresh context (system prompt only)", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "fresh-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.message_count == 1
    end

    test "fresh spawn gets depth = parent.depth + 1", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "depth-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.depth == state.depth + 1
    end

    test "fresh spawn at max depth has agents-spawn excluded from its tool list",
         %{space_id: space_id} do
      max = Config.configured_max_depth()
      vid = fresh_vocation()
      name = "maxdepth-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)
      state = %{state | depth: max}

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      child_state = :sys.get_state(pid)
      assert child_state.depth == max + 1
      refute Enum.any?(child_state.tools, &(&1.name == "agents-spawn"))
    end

    test "rejects a duplicate name in the space", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "dup-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      assert {:error, :duplicate_name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
    end
  end

  describe "spawn_agent_in_space/3 whitelist enforcement" do
    test "allows a whitelisted vocation and denies a non-whitelisted one" do
      allowed_vid = fresh_vocation()
      denied_vid = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "whitelist-#{System.unique_integer([:positive])}",
          root_vocation_id: allowed_vid,
          spawnable_vocation_ids: [allowed_vid]
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
               Supervisor.spawn_agent_in_space(state, allowed_name, allowed_vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, allowed_name) end)

      assert {:error, :vocation_not_spawnable} =
               Supervisor.spawn_agent_in_space(state, denied_name, denied_vid)

      refute Enum.member?(Agents.list_agents_for_space(space.id), denied_name)
    end

    test "an empty spawnable_vocation_ids list is unrestricted" do
      vid = fresh_vocation()

      {:ok, blueprint} =
        Blueprints.create_blueprint(%{
          name: "empty-wl-#{System.unique_integer([:positive])}",
          root_vocation_id: vid,
          spawnable_vocation_ids: []
        })

      {:ok, space} =
        Spaces.create_space(nil, %{
          name: "empty-wl-space-#{System.unique_integer([:positive])}",
          slug: "empty-wl-space-#{System.unique_integer([:positive])}",
          blueprint_id: blueprint.id
        })

      name = "any-#{System.unique_integer([:positive])}"
      state = coordinator_state(space.id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)
    end
  end

  describe "archive_agent/2" do
    test "stops the process and marks the row archived", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "archive-me-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

      assert :ok = Supervisor.archive_agent(space_id, name)

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
end
