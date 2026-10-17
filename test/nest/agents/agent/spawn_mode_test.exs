defmodule Nest.Agents.Agent.SpawnModeTest do
  @moduledoc """
  The mode a spawn names actually reaches the child.

  `agents-spawn`'s `mode` and `agents-batch`'s `set_mode` are both read into the
  spawn opts, and both used to be **dropped** on the way down: `SubAgent` passed
  name, vocation and model to `Supervisor.spawn_agent_in_space/4` and nothing
  else, so `PreSpawn.put_mode/1`'s authority was unreachable in production and a
  `plan` parent could spawn an `act` child — or spawn one and then raise it. The
  model was told it had control it did not have.

  Two levels are covered, because the drop was between them:

    * `Supervisor.spawn_agent_in_space/5` — the fresh-spawn path.
    * `SubAgent.handle_spawn_request/3` — the single funnel *both* tools go
      through (`agents-spawn` from `ToolLoop`, `agents-batch` from
      `BatchCoordinator` via `{:spawn_agent_request, pid, opts}`), which is where
      `BatchPlan.base_opts/1`'s `mode:` used to die.

  The `plan` parent is created in `plan` (`Agents.create_agent/3`'s `:mode`),
  because a mode is a property of the message that asked for it and there is no
  post-hoc setter — and the row is written from it, which is what the child's
  inherited mode is read from.

  It also pins that the **live** mode is the row's on both spawn paths, which is
  a separate failure from the dropped argument: a spawn starts from the
  *spawner's* attrs and `PreSpawn.put_mode/1` derives the mode into its own copy,
  so a child whose row says `plan` could still run `act` — writing a workspace
  its parent may not touch. The `"mine"` spelling made that worse than a
  cosmetic mismatch: it left `state.live.mode` as the literal `"mine"`, which
  `ChatPipeline.resolve_mode_and_caps/3` resolves to the **`act`** caps.
  """
  use Nest.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchPlan
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id}
  end

  describe "a fresh spawn's mode" do
    test "a named mode is the child's mode, on its row and in its live state", %{
      space_id: space_id
    } do
      state = coordinator_state(space_id)
      name = unique("plan-child")

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug, nil,
                 mode: "plan"
               )

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      # The row is what a restart and a later spawn read, so this is the
      # assertion that makes "the mode is persisted" true rather than claimed.
      assert %{mode: "plan"} = row_for(space_id, name)
      assert %{current_mode: "plan"} = Agent.get_public_info(child_pid(space_id, name), 1_000)
    end

    test "an omitted mode inherits the parent's, on the row and in the live state", %{
      space_id: space_id
    } do
      state = plan_coordinator(space_id)
      name = unique("inherit-child")

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert %{mode: "plan"} = row_for(space_id, name)

      # The row alone is not enough: the live mode is what `ctx.mode`/`ctx.caps`
      # are built from, so a child whose row says `plan` while its process runs
      # `act` writes the workspace the parent may not touch. The spawned child is
      # started from the *spawner's* attrs, which never carry the mode
      # `PreSpawn.put_mode/1` derived, so this is the assertion that catches it.
      assert %{current_mode: "plan"} = Agent.get_public_info(child_pid(space_id, name), 1_000)
    end

    test "the `mine` spelling reaches the child as the parent's mode, on the row and live", %{
      space_id: space_id
    } do
      # `"mine"` is the spelling both tools actually send by default
      # (`SpawnAgent`'s enum and `BatchPlan.base_opts/1`), so this is the common
      # path, not an edge case. Pre-fix the child's attrs kept the literal
      # `"mine"`: its row said `plan`, `state.live.mode` said `"mine"`, and
      # `ChatPipeline` resolved that to the `act` caps.
      state = plan_coordinator(space_id)
      name = unique("mine-child")

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug, nil,
                 mode: "mine"
               )

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert %{mode: "plan"} = row_for(space_id, name)
      assert %{current_mode: "plan"} = Agent.get_public_info(child_pid(space_id, name), 1_000)
    end

    test "a `plan` parent may spawn a `plan` child", %{space_id: space_id} do
      state = plan_coordinator(space_id)
      name = unique("plan-of-plan")

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug, nil,
                 mode: "plan"
               )

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert %{mode: "plan"} = row_for(space_id, name)
    end

    test "a `plan` parent may not spawn an `act` child, and no row is written", %{
      space_id: space_id
    } do
      state = plan_coordinator(space_id)
      name = unique("act-child")

      assert {:error, {:mode_refused, reason}} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug, nil,
                 mode: "act"
               )

      # The reason is a sentence the model can act on, not a code.
      assert reason =~ "never raised"
      assert row_for(space_id, name) == nil
      refute name in Agents.list_agents_for_space(space_id)
    end
  end

  describe "the clone path" do
    test "a clone takes the mode it is given, and may not be raised", %{space_id: space_id} do
      state = plan_coordinator(space_id)

      assert {:ok, child} =
               Supervisor.start_agent_with_parent(state, "carry on", nil, mode: "plan")

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, child) end)
      assert %{mode: "plan"} = row_for(space_id, child)

      # The same rule as a fresh spawn: a clone is a spawn, so a `plan` parent
      # cannot fork itself into `act`. No name is returned, because the refusal
      # happens before the child has one.
      assert {:error, {:mode_refused, _reason}} =
               Supervisor.start_agent_with_parent(state, "carry on", nil, mode: "act")
    end

    test "an omitted mode inherits the parent's, on the row and in the live state", %{
      space_id: space_id
    } do
      state = plan_coordinator(space_id)

      assert {:ok, child} = Supervisor.start_agent_with_parent(state, "carry on")

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, child) end)

      assert %{mode: "plan"} = row_for(space_id, child)
      assert %{current_mode: "plan"} = Agent.get_public_info(child_pid(space_id, child), 1_000)
    end
  end

  describe "the spawn request funnel — the path `agents-batch` uses" do
    test "a named mode reaches the child", %{space_id: space_id} do
      state = coordinator_state(space_id)
      name = unique("funnel-child")

      assert {:reply, {:ok, ^name}, _state} =
               SubAgent.handle_spawn_request(state, self(), %{
                 name: name,
                 vocation: fresh_vocation().slug,
                 query: "",
                 mode: "plan"
               })

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert %{mode: "plan"} = row_for(space_id, name)
    end

    test "a refused mode comes back as the request's error, and the model is told why", %{
      space_id: space_id
    } do
      state = plan_coordinator(space_id)
      name = unique("funnel-act")

      assert {:reply, {:error, {:mode_refused, reason}}, _state} =
               SubAgent.handle_spawn_request(state, self(), %{
                 name: name,
                 vocation: fresh_vocation().slug,
                 query: "",
                 mode: "act"
               })

      assert row_for(space_id, name) == nil

      # A batch is one call, so a per-child mode that cannot be honoured fails
      # the whole call — and the renderer passes the reason through rather than
      # wrapping it in `inspect`, so the model reads a sentence.
      assert BatchPlan.spawn_error_message({:mode_refused, reason}) ==
               "Could not spawn batch children: #{reason}"
    end
  end

  # Start a real coordinator in `space_id` and return its runtime state — the
  # spawn paths need a real parent (its name, its depth, and its persisted row
  # for `parent_id`).
  defp coordinator_state(space_id, opts \\ []) do
    name = unique("coord")

    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        test_model(),
        [
          name: name,
          vocation_id: AgentTestHelpers.vocation_id_for_test(),
          # Every agent needs a workspace, and a spawned child inherits its
          # parent's. Without one the coordinator could not spawn.
          workspace_path: AgentTestHelpers.default_test_workspace()
        ] ++ opts
      )

    AgentTestHelpers.ensure_cleanup(name)
    bridge(child_pid(space_id, name))
    state_of(name, space_id)
  end

  # The coordinator's *own* DB writes — a `set_mode` persists the row — run in
  # the agent's process, so it needs the test's sandbox connection.
  # `Agents.create_agent/3` does not hand it over; `AgentTestHelpers.start_agent/1`
  # does, which is the only reason the difference is invisible elsewhere.
  defp bridge(pid), do: Sandbox.allow(Nest.Repo, self(), pid)

  # The same coordinator, created in `plan`. There is no post-hoc setter: a mode
  # is a property of the message that asked for it, and a root agent is created
  # in the mode its creator names (`create_agent/3`'s `:mode`). The row is
  # written from it, so a child's inherited mode is `plan`.
  defp plan_coordinator(space_id) do
    state = coordinator_state(space_id, mode: "plan")

    assert %{mode: "plan"} = row_for(space_id, state.name)

    state
  end

  defp state_of(name, space_id) do
    {:ok, pid} = Supervisor.get_agent(space_id, name)
    # allowlist: harness — the spawn paths' state argument
    :sys.get_state(pid, 1_000)
  end

  defp child_pid(space_id, name) do
    {:ok, pid} = Supervisor.get_agent(space_id, name)
    pid
  end

  defp row_for(space_id, name) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, row} -> row
      _absent -> nil
    end
  end

  defp fresh_vocation do
    {:ok, vocation} =
      Vocations.upsert_vocation(%{
        name: "SpawnMode-#{System.unique_integer([:positive])}",
        description: "Spawn mode test",
        system_prompt: "You are a specialist.",
        tools: ["context"]
      })

    vocation
  end

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
