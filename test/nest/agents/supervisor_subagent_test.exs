defmodule Nest.Agents.SupervisorSubagentTest do
  @moduledoc """
  Tests for `Supervisor.start_agent_with_parent/2` and
  the cascade termination walk.

  This module uses `Nest.DataCase` because spawning a
  child writes a new `agents` row with `parent_id` /
  `depth` set; it also exercises the on-demand-load
  path (`build_attrs_for_start`) when restoring the
  parent later. Tests run `async: false` because they
  touch the persistent schema.

  ## What's covered

    * `start_agent_with_parent/2` returns `{:ok,
      child_name}` and the new row has `parent_id` =
      parent's integer `agents.id`, `depth` =
      `parent.depth + 1`.
    * The child's runtime carries `parent_name`
      matching the parent's `name` (so the child can
      dispatch `:child_completed` to the right parent
      without a pid lookup).
    * `Agents.delete_agent/1` cascade-walks children
      before terminating the parent.
    * A grandchild (clone_agent of clone_agent) is also
      cleaned up when the root parent dies.
    * `cascade_children_only/1` stops children WITHOUT
      terminating the named parent.
  """
  use Nest.DataCase, async: false

  import Eventually

  alias Nest.Agents
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Vocations

  setup do
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)
    on_exit(fn -> Application.put_env(:nest, :persistence, previous) end)

    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

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

      on_exit(fn -> safe_stop(child_name) end)
    end

    test "registers the parent/child link in ChildRegistry", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "do it")

      assert ChildRegistry.parent_of(child_name) == parent_name
      assert child_name in ChildRegistry.children_of(parent_name)

      on_exit(fn -> safe_stop(child_name) end)
    end
  end

  describe "stop_agent/1 cascade" do
    test "stops a parent and its spawned children in one call", %{vid: vid} do
      {:ok, parent_name, parent_pid, _} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_a} = Supervisor.start_agent_with_parent(parent_state, "a")
      {:ok, child_b} = Supervisor.start_agent_with_parent(parent_state, "b")

      :ok = Agents.delete_agent(parent_name)

      assert_registry_misses(parent_name)
      assert_registry_misses(child_a)
      assert_registry_misses(child_b)

      assert ChildRegistry.children_of(parent_name) == []
    end

    test "cascades through grandchildren (a child that itself spawned another)", %{vid: vid} do
      {:ok, parent_name, parent_pid, _} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "child")
      child_state = read_parent_state(child_name, via_registry(child_name))

      {:ok, grandchild_name} = Supervisor.start_agent_with_parent(child_state, "grandchild")

      :ok = Agents.delete_agent(parent_name)

      assert_registry_misses(parent_name)
      assert_registry_misses(child_name)
      assert_registry_misses(grandchild_name)
    end
  end

  describe "cascade_children_only/1" do
    test "stops children WITHOUT terminating the named parent", %{vid: vid} do
      {:ok, parent_name, parent_pid, _} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "child")

      :ok = Supervisor.cascade_children_only(parent_name)

      assert_registry_misses(child_name)
      assert Process.alive?(parent_pid)
    end
  end

  # ---- helpers ----

  defp upsert_test_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "Subagent Supervisor Test Vocation #{System.unique_integer([:positive])}",
        description: "Subagent test default",
        system_prompt: "You are a test agent.",
        tools: ["context", "clone_agent"],
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
        name: name,
        model: model,
        vocation_id: vid
      })

    # Start the agent under the application's supervisor
    # so `Agents.delete_agent/1`'s cascade walk can
    # terminate it via the same DynamicSupervisor.
    attrs = %{
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

        {:ok, name, parent_pid, row.id}

      _ ->
        # Bounce — fall through to the registry lookup
        # if the supervisor refused (already started by
        # a sibling test, etc.).
        parent_pid = via_registry(name)
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
    {:ok, attrs} = Persistence.build_attrs_for_start(name)
    info = Nest.Agents.Agent.get_public_info(pid)
    msgs = Nest.Agents.Agent.get_messages(pid)

    %Nest.Agents.Agent{
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
      parent_id: info.parent_id,
      parent_name: info.parent_name,
      chat_state: %Nest.Agents.Agent.ChatState{
        messages: msgs,
        next_message_index: attrs.next_message_index,
        last_compaction_index: attrs.last_compaction_index
      }
    }
  end

  defp assert_registry_misses(name) do
    assert eventually(fn -> AgentsRegistry.lookup(name) == {:error, :not_found} end,
             timeout: 1000
           )
  end

  defp child_row_by_name!(name) do
    {:ok, row} = Persistence.fetch_agent_by_name(name)
    row
  end

  defp via_registry(name) do
    {:ok, pid} = AgentsRegistry.lookup(name)
    pid
  end

  defp safe_stop(name) do
    case AgentsRegistry.lookup(name) do
      {:ok, _pid} -> :ok = Agents.delete_agent(name)
      _ -> :ok
    end
  end
end
