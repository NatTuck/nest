defmodule Nest.Agents.Agent.CloneAgentRegistrationTest do
  @moduledoc """
  Focused E2E tests for the parent side of `agents-spawn`, driven by a raw
  `GenServer.call` for `:spawn_agent_request` so the child's chat turn never
  runs:

    1. Stopping the parent tears the pending clone down with it, through the
       parent's own `terminate/2` cascade.
    2. A clone at max depth is refused at runtime with
       `{:error, :max_depth_reached}`, even though it still carries the
       `agents-spawn` tool it inherited.

  The spawn-and-register success path lives in `clone_agent_chat_stop_test.exs`
  (the same raw call, followed by a Stop) and in `clone_agent_flow_test.exs`
  (through the tool loop).
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

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
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _content, _mode, _sender -> :ok end)
    :ok
  end

  test "stopping the parent cascades through to the child" do
    Process.flag(:trap_exit, true)
    {parent_pid, parent_name} = AgentTestHelpers.start_agent()
    Mimic.allow(MockClient, self(), parent_pid)
    Mimic.allow(Nest.Agents, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1, 1_000)
    MockClient.start_link(parent_pid)

    {:ok, child_name} =
      GenServer.call(
        parent_pid,
        {:spawn_agent_request, self(), %{query: "x", clone_context: true}},
        2_000
      )

    # The child registers itself in the `Agents.Registry` inside its own
    # `init/1`, so the spawn reply above means its entry is there to monitor.
    {:ok, child_pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), child_name)

    # `Supervisor.stop_agent/2` fires `Process.exit/2` and returns before the
    # process is gone, and the child goes down through the parent's own
    # `terminate/2` cascade. Both deaths are real, arriving events: fence on
    # them rather than polling the registry for the entries to disappear.
    parent_ref = Process.monitor(parent_pid)
    child_ref = Process.monitor(child_pid)

    :ok = Supervisor.stop_agent(AgentTestHelpers.current_space_id(), parent_name)

    assert_receive {:DOWN, ^parent_ref, :process, ^parent_pid, _reason}, 1_000
    assert_receive {:DOWN, ^child_ref, :process, ^child_pid, _reason}, 1_000

    assert_registry_misses(parent_name)
    assert_registry_misses(child_name)
  end

  test "spawning from an agent at max depth errors (clone keeps the tool, spawn is rejected)" do
    Process.flag(:trap_exit, true)
    {parent_pid, parent_name} = AgentTestHelpers.start_agent()
    space_id = AgentTestHelpers.current_space_id()
    Mimic.allow(MockClient, self(), parent_pid)
    Mimic.allow(Nest.Agents, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1, 1_000)
    MockClient.start_link(parent_pid)

    # Force the parent to max depth — a clone at max depth still
    # has `agents-spawn` in its (inherited) tool list, so the
    # spawn must be rejected at runtime.
    max = Config.configured_max_depth()
    :sys.replace_state(parent_pid, &%{&1 | depth: max}, 1_000)

    assert {:error, :max_depth_reached} =
             GenServer.call(
               parent_pid,
               {:spawn_agent_request, self(), %{query: "x", clone_context: true}},
               2_000
             )

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, parent_name) end)
  end

  # Helpers

  defp swap_to_mock(state) do
    %{state | client_config: %{state.client_config | client: MockClient}}
  end

  # The caller has already fenced on the agent's `:DOWN`, so the process is
  # provably gone — and so is its `Nest.Agents.Registry` entry, because the
  # agent released it itself: `Agent.terminate/2`'s last act is
  # `Registry.release/2`, which runs before the process exits and therefore
  # before the `:DOWN` the caller waited on. No barrier is needed, and none is
  # possible. The registry's own link-`:EXIT` cleanup would have run a
  # scheduling hop later, and that hop is exactly what let a start under this
  # name be refused with an `:already_started` that
  # `Supervisor.start_under_supervisor/2` reports as success.
  defp assert_registry_misses(name) do
    assert AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name) ==
             {:error, :not_found}
  end
end
