defmodule Nest.Agents.Agent.CloneAgentChatStopTest do
  @moduledoc """
  E2E tests for the user-initiated Stop path's cascade. Pairs
  with `clone_agent_registration_test.exs`, which covers the
  GenServer-terminate cascade via `Agents.delete_agent/1`.
  Here we drive the cascade by sending `{:chat_stopped, _}`
  directly to the parent — the same message the ChatTurn
  would have sent through the channel → StopHandler →
  ChatTurn path — and verify the parent's `chat_stopped/1`
  walks `pending_children` and stops every descendant.

  See `notes/stop-children-when-parent-stopped.md` for the
  design and the race analysis this test pins down.
  """
  use Nest.DataCase, async: false

  import Mimic
  import Eventually

  alias Nest.Agents
  alias Nest.Agents.Agent.Broadcasts
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

    # Allow Mimic to stub `Nest.Agents.chat/2` in this test so the
    # parent's `handle_clone_request/3` doesn't actually drive an
    # LLM cycle on the spawned child.
    Mimic.copy(Nest.Agents)

    {:ok, vid: upsert_vocation()}
  end

  test "chat_stopped terminates the spawned child and clears pending_children",
       %{vid: vid} do
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    Mimic.stub(Nest.Agents, :chat, fn _name, _content -> :ok end)

    {:ok, child_name} =
      GenServer.call(parent_pid, {:clone_agent_request, self(), "x"}, 5_000)

    # Sanity: the parent registered us under the child's name
    # in pending_children.
    assert GenServer.call(parent_pid, :get_pending_children)[child_name] == self()

    # Drive the chat_stopped handler directly (see module doc).
    send(parent_pid, {:chat_stopped, parent_pid})
    new_state = :sys.get_state(parent_pid)

    # Bookkeeping reset.
    assert new_state.chat_state.pending_children == %{}
    assert new_state.chat_state.chat_turn_pid == nil
    assert new_state.chat_state.cancelled == false
    assert new_state.chat_state.status == :idle

    # The child's GenServer is gone (eventually, via supervisor
    # + ChildRegistry :DOWN cleanup).
    eventually(fn -> AgentsRegistry.lookup(child_name) == {:error, :not_found} end,
      timeout: 1_000
    )

    eventually(fn -> ChildRegistry.children_of(parent_name) == [] end,
      timeout: 1_000
    )

    on_exit_cleanup([parent_name])
  end

  test "the cascade walks grandchildren", %{vid: vid} do
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    Mimic.stub(Nest.Agents, :chat, fn _name, _content -> :ok end)

    # Spawn child A (the grandchild's parent) from the parent.
    {:ok, child_a_name} =
      GenServer.call(parent_pid, {:clone_agent_request, self(), "a"}, 5_000)

    {:ok, child_a_pid} = AgentsRegistry.lookup(child_a_name)
    MockClient.start_link(child_a_pid)

    # Spawn grandchild B from child A. The grandchild registration
    # goes through ChildRegistry the same way.
    {:ok, child_b_name} =
      GenServer.call(child_a_pid, {:clone_agent_request, self(), "b"}, 5_000)

    assert ChildRegistry.children_of(parent_name) == [child_a_name]
    assert ChildRegistry.children_of(child_a_name) == [child_b_name]

    # Drive chat_stopped on the parent. `stop_pending_children/1`
    # iterates pending_children (which has child_a_name → self),
    # calls `Supervisor.stop_agent(child_a_name)`, which walks
    # ChildRegistry to find child_b_name and terminates it via
    # child_a's own `cascade_children_only` call on terminate.
    # The parent itself stays alive — only descendants are
    # torn down (this is the contract that distinguishes this
    # cascade from `Agent.terminate/2`).
    send(parent_pid, {:chat_stopped, parent_pid})
    _ = :sys.get_state(parent_pid)

    # The parent is still alive.
    assert {:ok, _still_alive_parent} = AgentsRegistry.lookup(parent_name)

    eventually(fn -> AgentsRegistry.lookup(child_a_name) == {:error, :not_found} end,
      timeout: 1_000
    )

    eventually(fn -> AgentsRegistry.lookup(child_b_name) == {:error, :not_found} end,
      timeout: 1_000
    )

    eventually(fn -> ChildRegistry.children_of(parent_name) == [] end,
      timeout: 1_000
    )

    eventually(fn -> ChildRegistry.children_of(child_a_name) == [] end,
      timeout: 1_000
    )

    on_exit_cleanup([parent_name])
  end

  test "a child that completed just before stop is still merged into descendant_usage",
       %{vid: vid} do
    {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
    Mimic.allow(MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1)
    MockClient.start_link(parent_pid)

    Mimic.stub(Nest.Agents, :chat, fn _name, _content -> :ok end)

    {:ok, child_name} =
      GenServer.call(parent_pid, {:clone_agent_request, self(), "x"}, 5_000)

    # The child finishes *before* the parent's chat_stopped flush
    # runs. Cast the same shape `chat_idle/1`'s
    # `notify_parent_on_idle/2` would have produced.
    child_total = %{
      Broadcasts.empty_usage_totals()
      | output_tokens: 7,
        total_input_tokens: 5,
        total_tokens: 12
    }

    GenServer.cast(parent_pid, {:child_completed, child_name, "ok", child_total})

    # Drain the cast before flushing chat_stopped.
    _ = :sys.get_state(parent_pid)

    send(parent_pid, {:chat_stopped, parent_pid})
    new_state = :sys.get_state(parent_pid)

    # Usage was merged before pending_children got cleared.
    assert new_state.chat_state.pending_children == %{}
    assert new_state.llm_metrics.descendant_usage.output_tokens == 7
    assert new_state.llm_metrics.descendant_usage.total_input_tokens == 5
    assert new_state.llm_metrics.descendant_usage.total_tokens == 12

    # The orphan child from the cast is now in the supervisor's
    # bookkeeping, but pending_children is empty so the
    # stop_pending_children loop has no work to do for it. The
    # child itself can be cleaned up out-of-band.
    on_exit_cleanup([parent_name, child_name])
  end

  # Helpers

  defp upsert_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SubAgentChatStop Vocation #{System.unique_integer([:positive])}",
        description: "Sub-agent chat-stop cascade test",
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
    name = "stop-parent-#{System.unique_integer([:positive])}"
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

  defp on_exit_cleanup(names) do
    # Best-effort cleanup. `Agents.delete_agent/1` returns
    # `{:error, :not_found}` when the agent has already been
    # terminated by the cascade under test — those are
    # silently discarded.
    for name <- names do
      case AgentsRegistry.lookup(name) do
        {:ok, _pid} -> :ok = Agents.delete_agent(name)
        _ -> :ok
      end
    end
  end
end
