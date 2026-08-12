defmodule Nest.Agents.SupervisorSubagentTest do
  @moduledoc """
  Tests for `Supervisor.start_agent_with_parent/2` and
  the cascade termination walk.

  This module uses `Nest.DataCase` because spawning a
  child writes a new `agents` row with `parent_id` /
  `depth` set; it also exercises the on-demand-load
  path (`build_attrs_for_start`) when restoring the
  parent later. Tests run `async: true` — the sandbox
  rollback handles DB cleanup at test exit, so each
  test's row inserts are isolated.

  ## What's covered

    * `start_agent_with_parent/2` returns `{:ok,
      child_name}` and the new row has `parent_id` =
      parent's integer `agents.id`, `depth` =
      `parent.depth + 1`.
    * The child's runtime carries `parent_name`
      matching the parent's `name` (so the child can
      dispatch `:child_completed` to the right parent
      without a pid lookup).
    * `Supervisor.stop_agent/2` stops only the named agent;
      idle children (not in `pending_children`) survive.
  """
  use Nest.DataCase, async: true

  import Eventually

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    {:ok, vid} = upsert_test_vocation()
    {:ok, vid: vid}
  end

  describe "start_agent_with_parent/2" do
    test "spawns a child whose row carries the parent's id and depth+1", %{vid: vid} do
      {:ok, parent_name, parent_pid, parent_id} = start_root_parent(vid)

      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} =
        Supervisor.start_agent_with_parent(parent_state, "do a thing")

      child_row = child_row_by_name!(child_name)
      assert child_row.parent_id == parent_id
      assert child_row.depth == 1

      # Owns the parent's name on the runtime.
      info = Nest.Agents.Agent.get_public_info(via_registry(child_name))
      assert info.parent_name == parent_name
      assert info.parent_id == parent_id

      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)
    end

    test "registers the parent/child link in ChildRegistry", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "do it")

      assert ChildRegistry.parent_of(AgentTestHelpers.current_space_id(), child_name) ==
               parent_name

      assert child_name in ChildRegistry.children_of(
               AgentTestHelpers.current_space_id(),
               parent_name
             )

      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)
    end
  end

  describe "stop_agent/2" do
    test "stops only the named agent — idle children survive", %{vid: vid} do
      {:ok, parent_name, parent_pid, _} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()

      {:ok, child_a} = Supervisor.start_agent_with_parent(parent_state, "a")
      {:ok, child_b} = Supervisor.start_agent_with_parent(parent_state, "b")

      :ok = Supervisor.stop_agent(space_id, parent_name)

      assert_registry_misses(parent_name)
      # Idle children (not in `pending_children`) are left running.
      assert_registry_hits(child_a)
      assert_registry_hits(child_b)

      on_exit(fn -> safe_stop(space_id, child_a) end)
      on_exit(fn -> safe_stop(space_id, child_b) end)
    end
  end

  describe "parent_name restoration on agent restore" do
    # Phase 1 followup F1: after `Persistence.build_attrs_for_start/2`
    # loads a child agent from the DB, the returned attrs must carry
    # `parent_name` so the chat_turn_handler's `:child_completed`
    # notification reaches the parent. Without it the child
    # silently vanishes from the parent's view after a BEAM
    # restart, even though the DB row's `parent_id` is intact.
    test "child's restored attrs carry the parent's name", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "child")
      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)

      # Verify the live child carries parent_name (sanity).
      child_pid = via_registry(child_name)
      info = Nest.Agents.Agent.get_public_info(child_pid)
      assert info.parent_name == parent_name

      # Now exercise the restore path: `build_attrs_for_start/2`
      # is what `Supervisor.fetch_or_start_agent/2` calls when
      # the BEAM restarts. The DB row has `parent_id` set; the
      # returned attrs must also carry `parent_name`.
      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, child_name)
      assert attrs.parent_id != nil
      assert attrs.parent_name == parent_name
    end

    test "root agent's restored attrs have parent_name nil", %{vid: vid} do
      {:ok, _parent_name, _parent_pid, _} = start_root_parent(vid)

      space_id = AgentTestHelpers.current_space_id()

      [{name, _}] =
        Persistence.fetch_all_agents_for_space(space_id)
        |> Enum.take(1)
        |> Enum.map(&{&1.name, &1.id})

      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.parent_id == nil
      assert attrs.parent_name == nil
    end
  end

  # ---- helpers ----

  defp upsert_test_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "Subagent Supervisor Test Vocation #{System.unique_integer([:positive])}",
        description: "Subagent test default",
        system_prompt: "You are a test agent.",
        tools: ["context", "agents/spawn"],
        modes: %{
          "chat" => %{
            "description" => "General conversation.",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    {:ok, vid}
  end

  defp start_root_parent(vid) do
    name = "parent-#{System.unique_integer([:positive])}"
    model = %{name: "qwen3.5-plus", provider: "model-studio"}

    # Insert the agent row first (in the test process —
    # the agent's GenServer writes via the same
    # connection via `$callers`).
    {:ok, row} =
      Persistence.insert_agent(%{
        space_id: AgentTestHelpers.current_space_id(),
        name: name,
        model: model,
        vocation_id: vid
      })

    # Start the agent under the application supervisor
    # so `Supervisor.stop_agent/2` can
    # terminate it via the same DynamicSupervisor.
    attrs = %{
      space_id: AgentTestHelpers.current_space_id(),
      name: name,
      model: model,
      vocation_id: vid,
      vocation: Vocations.get_vocation(vid),
      parent_id: nil,
      depth: 0
    }

    case Supervisor.start_under_test(attrs) do
      {:ok, pid} ->
        parent_pid = pid

        Mimic.allow(Nest.LLM.MockClient, self(), parent_pid)
        :sys.replace_state(parent_pid, &swap_to_mock/1)

        # Parent cleanup: register the same DOWN-blocking
        # teardown that `AgentTestHelpers.start_agent/1` uses.
        # Tests that already call `Supervisor.stop_agent/2`
        # mid-test terminate the parent early; the registered
        # cleanup is idempotent (the monitor's
        # `Registry.lookup/2` returns `:not_found` for an
        # already-dead pid and `wait_for_pid_down/2`
        # short-circuits).
        AgentTestHelpers.ensure_cleanup(name)

        {:ok, name, parent_pid, row.id}

      _ ->
        # Bounce — fall through to the registry lookup
        # if the supervisor refused (already started by
        # a sibling test, etc.).
        parent_pid = via_registry(name)
        AgentTestHelpers.ensure_cleanup(name)

        {:ok, name, parent_pid, row.id}
    end
  end

  defp swap_to_mock(state) do
    %{state | client_config: %{state.client_config | client: Nest.LLM.MockClient}}
  end

  # Read the runtime state of a started parent by introspecting
  # the GenServer + loading the persisted attrs. We need name
  # + chat_state.messages + next_message_index + parent_id +
  # depth + parent_name + the full Vocation struct to feed
  # back into `Supervisor.start_agent_with_parent/2`.
  defp read_parent_state(name, pid) do
    {:ok, attrs} = Persistence.build_attrs_for_start(AgentTestHelpers.current_space_id(), name)
    info = Nest.Agents.Agent.get_public_info(pid)
    msgs = Nest.Agents.Agent.get_messages(pid)

    %Nest.Agents.Agent{
      space_id: attrs.space_id,
      name: info.name,
      model: info.model,
      vocation: attrs.vocation,
      vocation_id: info.vocation_id,
      workspace_path: attrs.workspace_path,
      llm_metrics: %Nest.Agents.Agent.LlmMetrics{
        context_limit: info.context_limit,
        context_limit_source: info.context_limit_source,
        usage_totals: info.usage,
        descendant_usage: info.descendant_usage
      },
      depth: info.depth,
      tree_position: %Nest.Agents.Agent.TreePosition{
        parent_id: info.parent_id,
        parent_name: info.parent_name
      },
      chat_state: %Nest.Agents.Agent.ChatState{
        messages: msgs,
        next_message_index: attrs.next_message_index,
        last_compaction_index: attrs.last_compaction_index
      }
    }
  end

  defp assert_registry_misses(name) do
    assert eventually(
             fn ->
               AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name) ==
                 {:error, :not_found}
             end,
             timeout: 1000
           )
  end

  defp assert_registry_hits(name) do
    assert {:ok, _pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name)
  end

  defp child_row_by_name!(name) do
    {:ok, row} = Persistence.fetch_agent(AgentTestHelpers.current_space_id(), name)
    row
  end

  defp via_registry(name) do
    {:ok, pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name)
    pid
  end

  # `ExUnit`'s on_exit handler runs in a separate pid that does
  # NOT own the test pid's sandbox checkout, so a DB write
  # here would fail with `DBConnection.OwnershipError`.
  # `Supervisor.stop_agent/2` terminates the GenServer only;
  # the DB row is cleaned up by `DataCase`'s sandbox rollback
  # at test exit. The single-message `:DOWN` wait is delegated
  # to `AgentTestHelpers.wait_for_pid_down/2` so the
  # parallel-test ownership race window is closed (the agent's
  # mailbox can't fire DB calls after `terminate/2` finishes).
  defp safe_stop(space_id, name) do
    _ = Supervisor.stop_agent(space_id, name)
    AgentTestHelpers.wait_for_pid_down(space_id, name)
  end
end
