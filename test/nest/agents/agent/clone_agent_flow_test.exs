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
       query. Nothing waits (decision 2): the tool result is the spawn's
       confirmation — unless the completion below lands first, which is exactly
       what this test arranges.
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

    * The spawn's tool result in the transcript is the machine's **synthetic
      backgrounded notice**, not the child's text: nothing waited for the
      answer.
    * The child's answer reaches the parent as a **delivered message** in the
      same turn, and the spawn's real confirmation arrives later as a notice.
    * The clone's fork notice names it, its depth, and its own scratch
      directory.

  The delivery's header, the synthetic notice's wording, the `descendant_usage`
  merge and the depth arithmetic are pinned by the tests that own them
  (`turn_backgrounding_test.exs`, `append_pairing_bridge_test.exs`,
  `sub_agent_test.exs`, `supervisor_spawn_test.exs`) and are not restated here.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTurnTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
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
  # the in-suite median and is also the `#21` cap on every test-side timeout, so
  # a genuinely stuck turn still fails — as a stuck turn, not as a flake.
  @turn_fence_ms 1_000

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

    :ok = Agent.chat(parent_pid, "delegate a thing")

    {_first, llm1} = next_request()
    release_llm(llm1)

    # Deterministic wait: `broadcast_subagent_creation/2` broadcasts
    # `agent:created` on the space topic (#41) right after the child is
    # registered, inside the parent's
    # `handle_spawn_request/3` — before the tool worker even gets its reply. The
    # parent then parks in the stubbed `Nest.Agents.chat/3` (see
    # `stub_child_chat/0`), so it is still `:executing_tools` when we cast the
    # child's completion below, and the cast is in its mailbox before the tool
    # worker can deliver the batch's result. Filter on `parentName` so
    # concurrent tests' broadcasts don't match.
    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())

    assert_receive {:agent_created, %{"name" => child_name, "parentName" => ^parent_name}},
                   2_000

    assert_receive {:child_chat_blocked, parent_pid}, 1_000

    space_id = AgentTestHelpers.current_space_id()
    {:ok, child_pid} = AgentsRegistry.lookup(space_id, child_name)

    # The parent processes this while the batch is still executing, so the
    # child's answer backgrounds the batch instead of waiting for the turn end.
    cast_child_completed_to_parent(parent_name, child_name, "the answer is 4")

    # Release the spawn call. The batch returns, and the parent handles the cast.
    send(parent_pid, :release_child_chat)

    {second, llm2} = next_request()

    mid = Agent.get_messages(parent_pid, 1_000)

    assert [synthetic] = tool_results(mid, "agents-spawn")

    # The spawn's tool result in the transcript is the *synthetic* one: the call
    # was moved to the background, and the confirmation arrives later as a
    # message. Nothing waited for the spawn.
    assert synthetic.content =~ "moved to the background"

    # The answer itself is already delivered into the parent's own transcript,
    # as the child's words, in the same turn.
    assert [_delivered] = delivered_texts(mid, "the answer is 4")

    # The batch returns: its real result has no live worker to settle it, so it
    # arrives as a queued notice.
    assert_receive {:chat_inbox, %{count: 1}}, 1_000

    # The notice is delivered at the batch's boundary — not by backgrounding the
    # next batch to make a landing place for it — so it is already in this turn:
    # the request the delivered answer started carries it. That is issue #161;
    # it used to get a turn of its own, one extra model round trip per
    # backgrounded result.
    assert Enum.any?(request_texts(second), &String.contains?(&1, "Spawned agent"))

    release_llm(llm2)
    await_idle()

    final = Agent.get_messages(parent_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(final)

    # The real confirmation arrives later as a message: the spawn's promise is
    # kept, just not by the tool result the model read mid-batch.
    assert [_notice] = delivered_texts(final, "Spawned agent")

    # The parent's turn really ended: one turn, whose single request answered
    # both the child's answer and the notice it carried.
    texts =
      for {:assistant, %{parts: parts}} <- final,
          %Part.Text{text: text} <- parts,
          do: text

    assert "parent final" in texts

    # The clone's fork notice carries its name and depth (its system message is
    # inherited verbatim from the parent, so this user-visible notice is the
    # only place to state the clone's true identity/depth).
    # allowlist: snapshot — depth + messages
    child_state = :sys.get_state(child_pid, 1_000)

    # ...and the fork notice itself — the `agents-spawn` tool result in the
    # clone's own sequence — carries its own scratch directory. That sentence is
    # the *only* place a clone can learn it: the clone's system message is
    # inherited verbatim from the parent (so it names the parent's directory),
    # and the tool descriptions no longer mention scratch paths at all (#35).
    # Deleting the sentence leaves the clone unable to find its own directory
    # while the suite stays green, so it is pinned here.
    fork_notice =
      child_state.chat_state.messages
      |> Enum.flat_map(fn
        {:tool, %{parts: parts}} ->
          for %Part.ToolResult{content: content} <- parts, do: content

        _other ->
          []
      end)
      |> Enum.join("\n")

    assert fork_notice =~ ~s(You are now the delegated clone, named "#{child_name}")
    assert fork_notice =~ "at depth #{child_state.depth}"
    assert fork_notice =~ "Your own scratch directory is `/tmp/#{child_name}/`"
  end

  # Wait for the turn to end, on the `chat:status` frame the machine emits when
  # it settles back to `:idle` (`Turn.run/6` broadcasts on every status change).
  # `AgentTestHelpers.start_agent/1` subscribes this test pid to the agent's
  # topic, so the frame is the event that decides when the turn is over;
  # `@turn_fence_ms` is only the failure bound. Polling
  # `Nest.Agents.Agent.Machine.status_for/1` instead would re-read the state
  # this frame already announced, and would let a broadcast regression pass as
  # success.
  defp await_idle do
    assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms
  end

  # Cast `:child_completed` to the parent, mimicking what the child's idle
  # completion sends in production. The parent finds the child in the machine's
  # children sub-machine, enqueues the answer into its own inbox, and merges the
  # child's usage into `descendant_usage`.
  defp cast_child_completed_to_parent(parent_name, child_name, response) do
    {:ok, parent_pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), parent_name)

    # A realistic child total; the parent's merge of it into
    # `descendant_usage` is pinned in `sub_agent_test.exs`.
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

  defp tool_results(messages, tool_name) do
    for {:tool, %{parts: parts}} <- messages,
        %Part.ToolResult{name: ^tool_name} = result <- parts,
        do: result
  end

  # The text parts of a parked request's messages: what the model was actually
  # asked, as opposed to what landed in the transcript.
  defp request_texts(messages) do
    for {_tag, %{parts: parts}} <- messages,
        %Part.Text{text: text} <- parts,
        do: text
  end

  defp delivered_texts(messages, needle) do
    for {:user, %{parts: parts}} <- messages,
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

    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _content, _mode, _sender ->
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
        tools: ["agents"]
      })

    vid
  end

  # #41: `agent:created` rides the per-space topic, so a test that wants to see
  # it subscribes to its own space rather than to the shared "lobby" topic.
  defp space_topic do
    Broadcasts.space_topic(AgentTestHelpers.current_space_id())
  end
end
