defmodule Nest.Agents.Agent.CloneAgentRegistrationTest do
  @moduledoc """
  Focused E2E test for the clone_agent wiring that does NOT
  drive LLM on the child. We:
    1. Start a parent under the supervisor.
    2. Issue a raw `GenServer.call` to the parent (acting as
       the tool worker) for `:clone_agent_request`.
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
  use Nest.DataCase, async: false

  import Mimic
  import Eventually

  alias Nest.Agents
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)
    on_exit(fn -> Application.put_env(:nest, :persistence, previous) end)

    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    # `:force_subagent_mock` is on by default in `config/test.exs`;
    # no per-test put/delete_env needed.

    # Allow Mimic to stub `Nest.Agents.chat/2` in this test.
    Mimic.copy(Nest.Agents)

    {:ok, vid: upsert_vocation()}
  end

  test "raw :clone_agent_request to the parent spawns, registers, and replies",
       %{vid: vid} do
    {:ok, parent_name, parent_pid, parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    # Stub `Nest.Agents.chat/2` so we don't actually fire
    # the child's chat turn — the parent's handler kicks
    # that off as a side effect of the spawn, but for this
    # test we only care about the spawn/registration
    # contract, not the LLM flow. (The LLM-on-child path
    # is exercised by `clone_agent_flow_test.exs`.)
    Mimic.stub(Nest.Agents, :chat, fn _name, _content ->
      :ok
    end)

    # The worker is the test process. The agent should
    # reply with `{:ok, child_name}` and remember our pid
    # under `pending_children[child_name]`.
    {:ok, child_name} =
      GenServer.call(
        parent_pid,
        {:clone_agent_request, self(), "do the thing"},
        5_000
      )

    assert is_binary(child_name)
    assert child_name != parent_name

    # The new child row has the right parent_id / depth.
    row = fetch_row!(child_name)
    assert row.parent_id == parent_id
    assert row.depth == 1

    # The parent's pending_children contains our pid under
    # the new child's name. (Without this, the parent's
    # worker dispatcher wouldn't know where to forward
    # `:clone_agent_result`.)
    pending_children = GenServer.call(parent_pid, :get_pending_children)
    assert pending_children[child_name] == self()

    on_exit_cleanup(parent_name, child_name)
  end

  test "stopping the parent cascades through to the child", %{vid: vid} do
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    {:ok, child_name} =
      GenServer.call(
        parent_pid,
        {:clone_agent_request, self(), "x"},
        5_000
      )

    :ok = Agents.delete_agent(parent_name)

    assert_registry_misses(parent_name)
    assert_registry_misses(child_name)
    assert ChildRegistry.children_of(parent_name) == []
  end

  # Helpers

  defp upsert_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SubAgentRegistration Vocation #{System.unique_integer([:positive])}",
        description: "Sub-agent raw-registration test",
        system_prompt: "x",
        tools: ["clone_agent", "context"],
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
    name = "parent-#{System.unique_integer([:positive])}"
    model = %{name: "qwen3.5-plus", provider: "model-studio"}

    {:ok, row} =
      Persistence.insert_agent(%{
        name: name,
        model: model,
        vocation_id: vid
      })

    attrs = %{
      name: name,
      model: model,
      vocation_id: vid,
      vocation: Vocations.get_vocation(vid),
      parent_id: nil,
      depth: 0
    }

    {:ok, parent_pid} = Supervisor.start_under_test(attrs)
    {:ok, name, parent_pid, row.id}
  end

  defp swap_to_mock(state) do
    %{state | client_config: %{state.client_config | client: MockClient}}
  end

  defp fetch_row!(name) do
    {:ok, row} = Persistence.fetch_agent_by_name(name)
    row
  end

  defp on_exit_cleanup(parent_name, child_name) do
    # Best-effort cleanup; if either is already gone, the
    # matching supervisor / registry stops are no-ops.
    case AgentsRegistry.lookup(parent_name) do
      {:ok, _pid} -> :ok = Agents.delete_agent(parent_name)
      _ -> :ok
    end

    case AgentsRegistry.lookup(child_name) do
      {:ok, _pid} -> :ok = Agents.delete_agent(child_name)
      _ -> :ok
    end
  end

  defp assert_registry_misses(name) do
    eventually(fn -> AgentsRegistry.lookup(name) == {:error, :not_found} end,
      timeout: 1_000
    )
  end
end
