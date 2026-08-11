defmodule Nest.Agents.SupervisorSpawnTest do
  @moduledoc """
  Tests for `Supervisor.spawn_agent_in_space/3` — the Phase 3
  entry point that creates an *independent*, fresh-context
  sub-agent in a space, authorized against the space's
  blueprint `spawnable_vocation_ids` whitelist.

  Unlike `start_agent_with_parent/2` (forked context, child
  registered in `ChildRegistry`), `spawn_agent_in_space/3`
  creates a specialist with only its system prompt, no
  `ChildRegistry` link, and `depth: 0`.

  ## What's covered

    * Unrestricted space (no blueprint) → any vocation spawns.
    * Whitelisted blueprint → allowed vocation spawns, denied
      vocation returns `{:error, :vocation_not_spawnable}`.
    * Duplicate name → `{:error, :duplicate_name}` (the
      `(space_id, name)` composite unique index).
    * Fresh context → the spawned agent's message count is 1
      (system prompt only).
  """
  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Spaces
  alias Nest.Vocations

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id}
  end

  # A minimal coordinator state. `spawn_agent_in_space/3` only
  # reads `space_id`, `model`, `created_by_user_id`, and
  # `shared`, so a partial struct suffices for these unit tests
  # (no need to boot a full Agent GenServer).
  defp coordinator_state(space_id) do
    %Agent{
      space_id: space_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      created_by_user_id: nil,
      shared: false
    }
  end

  defp fresh_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SpawnVocation-#{System.unique_integer([:positive])}",
        description: "Spawn test",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    vid
  end

  describe "spawn_agent_in_space/3 in an unrestricted space" do
    test "spawns an independent specialist with any vocation", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "specialist-#{System.unique_integer([:positive])}"

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(coordinator_state(space_id), name, vid)

      # Cleanup the spawned agent.
      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.vocation_id == vid
    end

    test "spawned agent has fresh context (system prompt only)", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "fresh-#{System.unique_integer([:positive])}"

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(coordinator_state(space_id), name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      # A fresh-context agent starts with exactly the system
      # message — no inherited user/assistant history.
      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.message_count == 1
    end

    test "rejects a duplicate name in the space", %{space_id: space_id} do
      vid = fresh_vocation()
      name = "dup-#{System.unique_integer([:positive])}"

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(coordinator_state(space_id), name, vid)

      assert {:error, :duplicate_name} =
               Supervisor.spawn_agent_in_space(coordinator_state(space_id), name, vid)

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

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(coordinator_state(space.id), name, vid)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)
    end
  end
end
