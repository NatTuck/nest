defmodule Nest.Agents.Agent.CloneAgentFlowTest do
  @moduledoc """
  E2E test that drives the parent's full chat turn through `MockClient.run/2`
  (exactly the surface the preflight gates) and pins what an `agents-spawn`
  call does to the parent's message list.

  ## Pipeline under test

    1. Parent Agent A starts under the Supervisor with `MockClient` (via the
       per-test `AgentTestHelpers` swap). A's vocation includes the
       `agents-spawn` tool.
    2. A's MockClient FIFO has (a) a tool response carrying
       `agents-spawn(query="compute 2+2", clone_context: true)`, then (b)
       `set_response("parent final")`.
    3. `Agent.chat(A, "delegate a thing")` fires the chain. A's first MockClient
       run consumes (a); `ToolLoop.run_spawn_agent/2` calls A's
       `:spawn_agent_request` handler, which spawns Agent B (via
       `Supervisor.start_agent_with_parent/2`), registers it, and delivers the
       query. Nothing waits (decision 2): the tool result is the confirmation.
    4. The test synthesizes B's completion: cast `:child_completed{child_name,
       response, usage}` to the parent. `SubAgent.handle_child_completed/4`
       merges the usage into `descendant_usage`, drops the running entry, and
       enqueues B's answer into the parent's own inbox (§2.1).
    5. The answer is drained at A's next turn boundary (issue #15), so the turn
       continues with it as a user message and A's second MockClient run
       consumes (b); A finishes and goes `:idle`.

  ## What's stubbed

    * `Nest.Agents.chat/2` — short-circuit the child's chat cycle. The child's
      `preloaded_messages` carry the parent's `assistant[agents-spawn]` tool_use
      paired with the child's own "you are the clone" result (see
      `notes/shared-message-structure.md`), so driving its LLM cycle would be
      valid; we stub it anyway to keep this test focused on the parent's
      pipeline.

  ## What's asserted

    * The tool result for `call_clone_1` is the **confirmation**, not the
      child's text: nothing waited for the answer.
    * The child's answer reaches the parent as a **delivered message** — a user
      message labelled `[Message from agent "<child>"]` — in the same turn, at
      the boundary after the tool result.
    * `parent.llm_metrics.descendant_usage.output_tokens > 0` — the usage merge
      ran.
    * The clone's fork notice names it and its depth.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTurnTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
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

  # The turn this file drives is a mocked LLM call, a real child spawn (DB
  # writes, a registry insert, a new process under the supervisor), a drain of
  # the child's answer and a second mocked LLM call. `Agent.chat/2` is a
  # `GenServer.cast`, so a fence placed after it covers the *whole* turn, and
  # 500 ms is not enough for that under load: the same shape measured p50
  # 18.7 ms / max 34.3 ms across 40 samples in the full suite, but p50 926 ms /
  # max 1534 ms (39 of 40 over 500 ms) under 48 CPU burners. 2000 ms is ~100x
  # the in-suite median and stays under ExUnit's 5 s per-test timeout, so a
  # genuinely stuck turn still fails — as a stuck turn, not as a flake.
  @turn_fence_ms 2_000

  test "a spawn's tool result is backgrounded, and the child's answer arrives as a message",
       %{vid: vid} do
    {parent_pid, parent_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    # `Mimic.stub(Nest.Agents, :chat, ...)` is scoped per-source-process. The
    # parent's GenServer process is started by `DynamicSupervisor.start_child`,
    # which doesn't propagate `$callers` from the test pid, so we must
    # explicitly allow it to use the stub set in `self()`.
    Mimic.allow(Nest.Agents, self(), parent_pid)

    park_llm_requests(parent_pid)

    MockClient.set_tool_response(%{
      text: "delegating",
      tool_calls: [
        %{
          id: "call_clone_1",
          name: "agents-spawn",
          arguments: %{"query" => "compute 2+2", "clone_context" => true}
        }
      ]
    })

    MockClient.set_response("parent final")
    MockClient.set_response("after the answer")

    :ok = Agent.chat(parent_pid, "delegate a thing")

    {first, llm1} = next_request()
    assert Enum.any?(user_texts(first), &(&1 =~ "delegate a thing"))
    release_llm(llm1)

    # Deterministic wait: `broadcast_subagent_creation/2` broadcasts
    # `agent:created` right after the child is registered, inside the parent's
    # `handle_spawn_request/3` — before the tool worker even gets its reply. The
    # parent then parks in the stubbed `Nest.Agents.chat/3` (see
    # `stub_child_chat/0`), so it is still `:executing_tools` when we cast the
    # child's completion below, and the cast is in its mailbox before the tool
    # worker can deliver the batch's result. Filter on `parentName` so
    # concurrent tests' broadcasts don't match.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:created",
                     payload: %{"name" => child_name, "parentName" => ^parent_name}
                   },
                   5_000

    assert_receive {:child_chat_blocked, parent_pid}, 5_000

    space_id = AgentTestHelpers.current_space_id()
    {:ok, child_pid} = AgentsRegistry.lookup(space_id, child_name)

    # The parent processes this while the batch is still executing, so the
    # child's answer backgrounds the batch instead of waiting for the turn end.
    cast_child_completed_to_parent(parent_name, child_name, "the answer is 4")

    # Release the spawn call. The batch returns, and the parent handles the cast.
    send(parent_pid, :release_child_chat)

    {second, llm2} = next_request()

    mid = :sys.get_state(parent_pid)
    AgentTestHelpers.assert_unique_message_indices(mid)

    # The child's answer is already in the transcript, behind the machine's
    # synthetic result and ack, and the batch's real result has not arrived.
    assert Enum.map(mid.chat_state.messages, &elem(&1, 0)) ==
             [:system, :user, :assistant, :tool, :assistant, :user]

    assert [synthetic] = tool_results(mid, "agents-spawn")

    # The spawn's tool result in the transcript is the *synthetic* one: the call
    # was moved to the background, and the confirmation arrives later as a
    # message. It does not name the child — nothing waited for the spawn.
    assert synthetic.content =~ "moved to the background"
    assert synthetic.content =~ "arrive later as a message"
    refute synthetic.content =~ child_name

    # The answer itself is delivered into the parent's own transcript as the
    # child's words, labelled with the child it came from, in the same turn.
    assert [delivered] = delivered_texts(mid, "the answer is 4")
    assert delivered =~ ~s([Message from agent "#{child_name}"])
    assert Enum.any?(user_texts(second), &(&1 =~ "the answer is 4"))

    # The batch returns: its real result has no live worker to settle it, so it
    # arrives as a queued notice.
    assert_receive {:chat_inbox, %{count: 1}}, 500

    # The response to the request the delivered answer rode in on, then the
    # notice's own turn.
    release_llm(llm2)
    {_third, llm3} = next_request()
    release_llm(llm3)

    await_idle(parent_pid)

    parent_state = :sys.get_state(parent_pid)
    AgentTestHelpers.assert_unique_message_indices(parent_state)

    # The real confirmation arrives later as a message, and it names the child
    # and says where the answer goes: the spawn's promise is kept, just not by
    # the tool result the model read mid-batch.
    assert [notice] = delivered_texts(parent_state, "Spawned agent")

    assert notice =~ child_name
    assert notice =~ "arrive as a message"
    refute notice =~ "the answer is 4"

    # The synthesized child's usage was merged into the parent's totals.
    assert parent_state.llm_metrics.descendant_usage.output_tokens > 0

    # The parent's turn really ended: the turn the delivery continued answered
    # with its final text, and the notice's own turn answered after it.
    texts =
      for {:assistant, %{parts: parts}} <- parent_state.chat_state.messages,
          %Part.Text{text: text} <- parts,
          do: text

    assert "parent final" in texts
    assert "after the answer" in texts

    # The clone's fork notice carries its name and depth (its system message is
    # inherited verbatim from the parent, so this user-visible notice is the
    # only place to state the clone's true identity/depth).
    child_state = :sys.get_state(child_pid)
    assert child_state.depth == parent_state.depth + 1

    ack_text =
      child_state.chat_state.messages
      |> Enum.filter(fn {role, _} -> role == :assistant end)
      |> Enum.flat_map(fn {_role, %{parts: parts}} ->
        for %Part.Text{text: t} <- parts, do: t
      end)
      |> Enum.join(" ")

    assert ack_text =~ "named \"#{child_name}\""
    assert ack_text =~ "at depth #{child_state.depth}"
  end

  # Wait until the agent has settled to `:idle`, on the machine's own status.
  #
  # Polling the authoritative status rather than waiting for the `chat:status`
  # broadcast means a missed or reordered broadcast can never be the reason this
  # fails, and the condition waited on is exactly the one the test-teardown
  # invariant checks. See `@turn_fence_ms` for the budget.
  defp await_idle(pid) do
    assert Eventually.eventually(
             fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
             timeout: @turn_fence_ms
           )
  end

  # Cast `:child_completed` to the parent, mimicking what the child's idle
  # completion sends in production. The parent finds the child in the machine's
  # children sub-machine, enqueues the answer into its own inbox, and merges the
  # child's usage into `descendant_usage`.
  defp cast_child_completed_to_parent(parent_name, child_name, response) do
    {:ok, parent_pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), parent_name)

    # Realistic child usage — `output_tokens: 42` proves the parent's
    # `descendant_usage` actually got merged into.
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

  defp tool_results(state, tool_name) do
    for {:tool, %{parts: parts}} <- state.chat_state.messages,
        %Part.ToolResult{name: ^tool_name} = result <- parts,
        do: result
  end

  defp delivered_texts(state, needle) do
    for {:user, %{parts: parts}} <- state.chat_state.messages,
        %Part.Text{text: text} <- parts,
        text =~ needle,
        do: text
  end

  # The child is spawned with a valid, paired origin story (its own "you are the
  # clone" tool result), but this test exercises the parent's chat pipeline, not
  # the child's, so `Agents.chat/2` is stubbed to no-op and the child's GenServer
  # stays idle. The stub parks the *parent* (it is called from the parent's own
  # `handle_spawn_request/3`), so the test controls when the spawn call returns
  # and the batch's result can follow — which is what makes the mid-batch state
  # below reproducible. The `after` is a safety valve so a failing test cannot
  # leave the parent parked for long.
  defp stub_child_chat do
    test_pid = self()

    Mimic.copy(Nest.Agents)

    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _content ->
      send(test_pid, {:child_chat_blocked, self()})

      receive do
        :release_child_chat -> :ok
      after
        1_000 -> :ok
      end

      :ok
    end)
  end

  defp upsert_spawn_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "CloneAgentFlow #{System.unique_integer([:positive])}",
        description: "End-to-end agents-spawn test",
        system_prompt: "Delegate work to a subagent when asked.",
        tools: ["agents"],
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
