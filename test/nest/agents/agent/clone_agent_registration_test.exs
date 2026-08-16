defmodule Nest.Agents.Agent.CloneAgentRegistrationTest do
  @moduledoc """
  Focused E2E test for the agents-spawn wiring that does NOT
  drive LLM on the child. We:
    1. Start a parent under the supervisor.
    2. Issue a raw `GenServer.call` to the parent (acting as
       the tool worker) for `:spawn_agent_request`.
    3. Verify the parent spawns a child, registers it in the
       ChildRegistry, replies with the child's name, and
       remembers the worker pid under that child.

  The point: cover the end-to-end Agent wiring (handle_call
  → SubAgent → start_agent_with_parent → ChildRegistry →
  Agents.chat kickoff) without depending on the child's chat
  task actually running to completion. Full LLM-driven
  E2E lives in the planned but deferred
  `clone_agent_flow_test.exs`.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Eventually

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    # `:force_subagent_mock` is on by default in `config/test.exs`;
    # no per-test put/delete_env needed.

    # Allow Mimic to stub `Nest.Agents.chat/2` in this test.
    Mimic.copy(Nest.Agents)
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _content -> :ok end)

    {:ok, vid: upsert_vocation()}
  end

  test "raw :spawn_agent_request to the parent spawns, registers, and replies",
       %{vid: vid} do
    Process.flag(:trap_exit, true)
    {:ok, parent_name, parent_pid, parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    Mimic.allow(Nest.Agents, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    # The worker is the test process. The agent should
    # reply with `{:ok, child_name}` and remember our pid
    # under `pending_children[child_name]`.
    {:ok, child_name} =
      GenServer.call(
        parent_pid,
        {:spawn_agent_request, self(), %{query: "do the thing", clone_context: true}},
        5_000
      )

    assert is_binary(child_name)
    assert child_name != parent_name

    # The new child row has the right parent_id / depth.
    row = fetch_row!(child_name)
    parent_row = fetch_row!(parent_name)
    assert row.parent_id == parent_row.id
    assert row.depth == 1
    _ = parent_id

    # The parent's pending_children contains our pid under
    # the new child's name. (Without this, the parent's
    # worker dispatcher wouldn't know where to forward
    # `:spawn_agent_result`.)
    pending_children = GenServer.call(parent_pid, :get_pending_children)
    assert pending_children[child_name] == self()

    on_exit_cleanup(parent_name, child_name)
  end

  test "stopping the parent cascades through to the child", %{vid: vid} do
    Process.flag(:trap_exit, true)
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    Mimic.allow(Nest.Agents, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    {:ok, child_name} =
      GenServer.call(
        parent_pid,
        {:spawn_agent_request, self(), %{query: "x", clone_context: true}},
        5_000
      )

    :ok = Supervisor.stop_agent(AgentTestHelpers.current_space_id(), parent_name)

    assert_registry_misses(parent_name)
    assert_registry_misses(child_name)
    assert ChildRegistry.children_of(AgentTestHelpers.current_space_id(), parent_name) == []
  end

  test "spawning from an agent at max depth errors (clone keeps the tool, spawn is rejected)",
       %{vid: vid} do
    Process.flag(:trap_exit, true)
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    space_id = AgentTestHelpers.current_space_id()
    Mimic.allow(MockClient, self(), parent_pid)
    Mimic.allow(Nest.Agents, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    # Force the parent to max depth — a clone at max depth still
    # has `agents-spawn` in its (inherited) tool list, so the
    # spawn must be rejected at runtime.
    max = Config.configured_max_depth()
    :sys.replace_state(parent_pid, &%{&1 | depth: max})

    assert {:error, :max_depth_reached} =
             GenServer.call(
               parent_pid,
               {:spawn_agent_request, self(), %{query: "x", clone_context: true}},
               5_000
             )

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, parent_name) end)
  end

  # Helpers

  defp upsert_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SubAgentRegistration Vocation #{System.unique_integer([:positive])}",
        description: "Sub-agent raw-registration test",
        system_prompt: "x",
        tools: ["agents-spawn", "context-check", "context-compact"],
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end

  defp start_parent(vid) do
    # Use the standard helper. The original signature returned
    # `{:ok, name, pid, row.id}` — the row id is unused in the
    # test body (only `name` and `pid` are matched), so the
    # helper's `{pid, name}` return is reshaped into the
    # legacy tuple with `nil` for the now-unused id.
    _ = vid
    {parent_pid, name} = AgentTestHelpers.start_agent()
    {:ok, name, parent_pid, nil}
  end

  defp swap_to_mock(state) do
    %{state | client_config: %{state.client_config | client: MockClient}}
  end

  defp fetch_row!(name) do
    {:ok, row} = Persistence.fetch_agent(AgentTestHelpers.current_space_id(), name)
    row
  end

  # Best-effort cleanup. A DB write here would require the
  # test pid's sandbox checkout, but `on_exit` runs in
  # `ExUnit.OnExitHandler` — no ownership. Use
  # `Supervisor.stop_agent/1` (GenServer only;
  # no DB write) and let the DataCase sandbox rollback handle
  # row cleanup at test exit.
  defp on_exit_cleanup(parent_name, child_name) do
    for name <- [parent_name, child_name] do
      case AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name) do
        {:ok, _pid} -> :ok = Supervisor.stop_agent(AgentTestHelpers.current_space_id(), name)
        _ -> :ok
      end
    end
  end

  defp assert_registry_misses(name) do
    eventually(
      fn ->
        AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name) == {:error, :not_found}
      end,
      timeout: 1_000
    )
  end
end
