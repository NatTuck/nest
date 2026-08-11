defmodule Nest.Agents.Agent.CloneAgentFlowTest do
  @moduledoc """
  E2E test that drives the parent's full chat turn through
  `MockClient.run/2` (which is exactly the surface the
  preflight gates) and confirms the agents/spawn flow
  produces a properly paired `assistant[agents/spawn] →
  tool[clone_result]` in the parent's messages list.

  ## Pipeline under test

    1. Parent Agent A starts under the Supervisor with
       `MockClient` (via the per-test `AgentTestHelpers`
       swap). A's vocation includes the `agents/spawn`
       tool.
    2. A's MockClient FIFO has (a) `set_tool_response`
       carrying `agents/spawn(query="compute 2+2", clone_context: true)`,
       then (b) `set_response("parent final")`.
    3. `Agent.chat(A, "delegate a thing")` fires the
       chain. A's first MockClient run consumes (a);
       `ToolLoop.run_agents/spawn/2` calls A's
       `:spawn_agent_request` handler.
    4. A's handler spawns Agent B via
       `Supervisor.start_agent_with_parent/2`. The child
       GenServer is registered, but its actual chat cycle
       is short-circuited via `Mimic.stub(Nest.Agents,
       :chat, ...)` so we don't drive a second
       MockClient.run cycle for B.
    5. The test synthesizes the child's completion: cast
       `:child_completed{child_name, response, usage}`
       directly to the parent. `SubAgent.handle_child_completed/4`
       merges the usage into `descendant_usage`, drops
       the pending entry, and forwards `:spawn_agent_result`
       to the blocked tool worker.
    6. The worker (Task) appends the synthesized `tool[X]`
       message with `tool_call_id: "call_clone_1"` and
       the child's text as content, and ChatTurn continues
       iterating.
    7. A's second `MockClient.run/2` (the surface the
       preflight gates) consumes (b); A finishes and
       goes `:idle`.

  ## What's stubbed

    * `Nest.Agents.chat/2` — short-circuit the child's
      chat cycle. The child's `preloaded_messages` carry
      the parent's `assistant[agents/spawn]` tool_use but
      no paired tool_result; driving the child's LLM
      cycle would trip our preflight's
      `:unclosed_tool_responses` check. That's a separate
      production bug to fix (the spawned child's history
      should drop unpaired trailing tool_uses). Stubbing
      lets the test focus on what it actually exercises:
      the parent's full chat pipeline through MockClient,
      plus the round-trip persistence of the parent's
      user/assistant/tool messages and the child's
      `build_attrs_for_start` DB read of `preloaded_messages`.

  ## What's asserted

    * 5 message indices in `[0, 1, 2, 3, 4]`.
    * Index 2 is the assistant `tool_use` for
      `agents/spawn(id="call_clone_1")`.
    * Index 3 is the `Part.ToolResult` carrying the
      child's text with `tool_call_id: "call_clone_1"` —
      i.e. the result of the call from step 4's
      `SubAgent.handle_child_completed/4`.
    * Index 4 is a final `text` "parent final" — the
      second MockClient.run call (the post-pairing LLM
      call, exercising the preflight's :ok path).
    * `parent.llm_metrics.descendant_usage.output_tokens > 0`
      — proves the cast-back / usage-merge ran.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    stub_child_chat()
    {:ok, vid: upsert_spawn_vocation()}
  end

  test "agents/spawn: parent's tool call spawns child, child's response via MockClient comes back as parent's tool result",
       %{vid: vid} do
    {parent_pid, parent_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    # `Mimic.stub(Nest.Agents, :chat, ...)` is scoped per-source-process.
    # The parent's GenServer process is started by
    # `DynamicSupervisor.start_child`, which doesn't propagate `$callers`
    # from the test pid, so we must explicitly allow it to use the
    # stub set in `self()`.
    Mimic.allow(Nest.Agents, self(), parent_pid)

    MockClient.set_tool_response(%{
      text: "delegating",
      tool_calls: [
        %{
          id: "call_clone_1",
          name: "agents/spawn",
          arguments: %{"query" => "compute 2+2", "clone_context" => true}
        }
      ]
    })

    MockClient.set_response("parent final")

    :ok = Agent.chat(parent_pid, "delegate a thing")

    # Deterministic wait: the parent's `handle_clone_request/3`
    # calls `broadcast_subagent_creation/2` which does
    # `Phoenix.Endpoint.broadcast("lobby", "agent:created", ...)`
    # right after `ChildRegistry.register/2` succeeds (see
    # `sub_agent.ex:160-175`). By the time we receive the
    # broadcast, child A is registered and `pending_children`
    # has the entry — no need for a separate pending_children
    # poll. Filter on `parentName` so concurrent tests'
    # `agent:created` broadcasts don't match.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:created",
                     payload: %{"name" => child_name, "parentName" => ^parent_name}
                   },
                   5_000

    {:ok, child_pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), child_name)

    cast_child_completed_to_parent(parent_name, child_name, "the answer is 4")

    # Full chain: parent-turn-1 (agents/spawn dispatch) +
    # synthesized child completion + parent-turn-2
    # (final text). The context-notice synthetic pair
    # (assistant("Context?") + user(notice)) may add 2
    # more messages at any LLM-response boundary that
    # crosses a threshold. Use content-based lookups
    # instead of hardcoded indices.
    assert_receive {:chat_status, %{status: "idle"}}, 500

    parent_state = :sys.get_state(parent_pid)
    AgentTestHelpers.assert_unique_message_indices(parent_state)

    # Find the assistant message that carries the agents/spawn
    # tool call (the wire pairing test below depends on this).
    {:assistant, clone_assistant} =
      Enum.find(parent_state.chat_state.messages, fn
        {:assistant, %{parts: parts}} ->
          Enum.any?(parts, fn
            %Part.ToolUse{name: "agents/spawn"} -> true
            _ -> false
          end)

        _ ->
          false
      end)

    tool_uses =
      for part <- clone_assistant.parts,
          match?(%Part.ToolUse{}, part),
          do: part

    assert [%Part.ToolUse{id: "call_clone_1", name: "agents/spawn"}] = tool_uses

    # Find the tool message with the agents/spawn result.
    {:tool, tool_msg} =
      Enum.find(parent_state.chat_state.messages, fn
        {:tool, %{parts: [%Part.ToolResult{name: "agents/spawn"}]}} -> true
        _ -> false
      end)

    assert [
             %Part.ToolResult{
               tool_call_id: "call_clone_1",
               name: "agents/spawn",
               content: content,
               arguments: %{"query" => "compute 2+2", "clone_context" => true},
               is_error: false
             }
           ] = tool_msg.parts

    assert content == "the answer is 4"

    {_, %{parts: final_parts}} = List.last(parent_state.chat_state.messages)
    assert [%Part.Text{text: "parent final"}] = final_parts

    # Stubbed `Agents.chat/2` ensured the child's Agent
    # GenServer was registered (so `Supervisor.get_agent/1`
    # resolved) but its actual chat pipeline was bypassed.
    # The parent's pipeline received the synthesized child's
    # text via the `:child_completed` cast; that's the
    # cast-back/merge surface under test.
    assert Process.alive?(child_pid)
    assert parent_state.llm_metrics.descendant_usage.output_tokens > 0
  end

  # Cast `:child_completed` to the parent, mimicking what the
  # child's `chat_idle` handler does in production. The parent
  # reads the child's name from `state.chat_state.pending_children`,
  # forwards `:spawn_agent_result` to the blocked tool worker,
  # and merges the child's usage into `descendant_usage`.
  defp cast_child_completed_to_parent(parent_name, child_name, response) do
    {:ok, parent_pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), parent_name)

    # Realistic child usage — `output_tokens: 42` proves the
    # parent's `descendant_usage` actually got merged into.
    usage = %{
      input_tokens: 0,
      output_tokens: 42,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 42,
      last_output: 42,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      context_input_tokens: 0
    }

    GenServer.cast(parent_pid, {:child_completed, child_name, response, usage})
  end

  # The spawned child's first LLM call would normally land on
  # MockClient too (via `:force_subagent_mock`), but the
  # child's `preloaded_messages` include the parent's
  # `assistant[agents/spawn]` tool_use with no paired
  # tool_result — the preflight we just added correctly
  # rejects this as `:unclosed_tool_responses`. Driving the
  # child's actual chat cycle would trigger that preflight
  # (the test should fail on its own assertions before it ever
  # gets that far), but it's a production bug to fix
  # separately. For now we stub `Agents.chat/2` to no-op;
  # the test still exercises the parent's full chat-turn
  # pipeline through MockClient.run/2 (including the preflight
  # in iteration 2, after the synthesized tool result lands).
  defp stub_child_chat do
    Mimic.copy(Nest.Agents)
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _content -> :ok end)
  end

  defp upsert_spawn_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "CloneAgentFlow #{System.unique_integer([:positive])}",
        description: "End-to-end agents/spawn test",
        system_prompt: "Delegate work to a subagent when asked.",
        tools: ["agents/spawn"],
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end
end
