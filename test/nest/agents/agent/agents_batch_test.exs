defmodule Nest.Agents.Agent.AgentsBatchTest do
  @moduledoc """
  E2E test for the `agents-batch` fork-join tool.

  Drives a parent's full chat turn through `MockClient` where the model makes ONE
  `agents-batch` call. The call returns a confirmation immediately; the fan-out
  runs in a supervised coordinator (§2.3), and the aggregate — a JSON array of
  each child's response, in item order — arrives later as a message in the
  parent's own inbox. The children report to the coordinator, not to the parent,
  so the aggregate is the batch's only traffic in the parent's transcript — each
  child's own answer arrives as its own message only when the coordinator is
  gone (the crash test below).

  ## What's stubbed

  * `Nest.Agents.chat/3` — short-circuits each child's chat cycle (the child's
    `preloaded_messages` carry the parent's unpaired tool_use, which the child's
    preflight would reject; and driving three real child cycles is out of scope).
    The child is still spawned + registered, so `archive` and the
    cast-back/usage-merge run for real.

  ## What's asserted

  * The `agents-batch` tool result is the **confirmation**: it names the
    children and says where the aggregate arrives.
  * The aggregate arrives as a delivered message and decodes to the children's
    answers in item order.
  * `descendant_usage.output_tokens > 0` (usage-merge ran for the children),
    `pending_children` is empty, and `archive` (default true) cleaned up.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchCoordinator
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    stub_child_chat()
    {:ok, vid: upsert_batch_vocation()}
  end

  test "a batch returns a confirmation, and the aggregate arrives as a message in item order",
       %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_1", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"]
    })

    # Subscribe before collecting so the first creation can't slip past.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

    # The coordinator spawns children in item order (sequential `pace`), so the
    # creation broadcasts arrive in item order. Collect all three, filtered by
    # parent so a concurrent test's broadcast can't match.
    child_names = collect_child_names(parent_name, 3)

    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

    # Children are named from their item (no prefix here), not by the
    # adjective-generator.
    assert child_names == ["alpha", "beta", "gamma"]

    # The tool result is the confirmation, not the aggregate: nothing waited.
    confirmation = batch_tool_result(:sys.get_state(parent_pid)).content
    assert confirmation =~ "Fanned 3 item(s)"
    assert confirmation =~ "alpha, beta, gamma"
    assert confirmation =~ "aggregate"
    refute confirmation =~ "asynchronous"

    # Synthesize each child's completion, each with a distinct response, so an
    # order bug would surface.
    for {name, item} <- Enum.zip(child_names, ["alpha", "beta", "gamma"]) do
      cast_child_completed(parent_pid, name, "#{item}-done")
    end

    assert ["alpha-done", "beta-done", "gamma-done"] =
             await_aggregate(parent_pid, ~s(["alpha-done))

    parent_state = :sys.get_state(parent_pid)
    AgentTestHelpers.assert_unique_message_indices(parent_state)

    # The children report to the coordinator, so the parent reads the batch
    # once: the aggregate is the only batch traffic in its transcript.
    assert delivered_texts(parent_state, "Message from agent") == []

    # Usage-merge ran for the three children.
    assert parent_state.llm_metrics.descendant_usage.output_tokens > 0

    # No children left running, and `archive` (default true) cleaned up: the
    # coordinator archives each child after forwarding its response. The DB
    # `archived` flag is the deterministic proof (no liveness polling).
    assert Machine.pending_children(parent_state.live.machine) == %{}

    assert Enum.all?(
             child_names,
             &(Children.status(parent_state.live.machine.children, &1) == :completed)
           )

    assert_children_archived(space_id, child_names)
  end

  test "a child that finished its turn with no text becomes a marker slot", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_no_text", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn ->
      Enum.each([child0, child1], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # A child whose final assistant message carried no text reports an empty
    # response, which the runtime turns into a notice — the slot must say so
    # instead of going out as `""`.
    cast_child_completed(parent_pid, child0, "")
    cast_child_completed(parent_pid, child1, "beta-done")

    assert [first, "beta-done"] = await_aggregate(parent_pid, ~s(["[error:))
    assert String.starts_with?(first, "[error:")
    assert first =~ "without producing any text"

    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}
  end

  test "a child that dies before responding fails its slot and is not archived", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_die", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1, child2] = collect_child_names(parent_name, 3)

    on_exit(fn ->
      Enum.each([child1, child2], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # Kill the first child before it completes. ChildRegistry's DOWN
    # notification reaches the parent, which delivers the news into its own
    # inbox — so the coordinator's slot resolves immediately instead of waiting
    # out the 5-minute timeout.
    assert :ok = Supervisor.stop_agent(space_id, child0)

    # The other two complete normally.
    cast_child_completed(parent_pid, child1, "beta-done")
    cast_child_completed(parent_pid, child2, "gamma-done")

    assert [first, "beta-done", "gamma-done"] = await_aggregate(parent_pid, ~s(["[error:))
    assert String.starts_with?(first, "[error:")
    assert first =~ "stopped before it answered"

    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}

    # A failed child is never auto-archived (unlike a completed one).
    {:ok, failed_row} = Nest.Persistence.fetch_agent(space_id, child0)
    assert failed_row.archived == false
  end

  test "items still pending past their deadline time out into marker slots", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)

    run_batch(parent_pid, "call_batch_timeout", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"],
      "timeout" => 1
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [_child0, _child1] = collect_child_names(parent_name, 2)

    assert [first, second] = await_aggregate(parent_pid, "timed out after")
    assert first =~ "timed out after 1ms"
    assert second =~ "timed out after 1ms"
    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}
  end

  test "a timed-out item under fail_fast stops the rest and reports it", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)

    run_batch(parent_pid, "call_batch_fail_fast", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"],
      "timeout" => 1,
      "on_error" => "fail_fast"
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [_child0, _child1] = collect_child_names(parent_name, 2)

    # The confirmation promises exactly what fail_fast does, before anything
    # fails: it stops at the first failure and reports the slots it filled.
    confirmation = batch_tool_result(:sys.get_state(parent_pid)).content
    assert confirmation =~ "stops at the first failure"
    assert confirmation =~ "reports the slots it filled before it stopped"

    # fail_fast reports the stop in the inbox rather than as a tool result: the
    # call had already returned its confirmation when the deadline passed.
    assert [report] = await_message(parent_pid, "stopped:")
    assert report =~ "Batch of 2 stopped: an item timed out after 1ms"

    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}
  end

  test "a batch whose coordinator dies falls back to per-child messages", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_orphan", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn -> Enum.each([child0, child1], &Supervisor.stop_agent(space_id, &1)) end)

    coordinator = batch_target(parent_pid, child0)
    assert is_pid(coordinator)

    # A `:kill`ed task never runs the coordinator's rescue, so there is no
    # coordinator line to assert here — its own report is asserted in
    # `batch_coordinator_test.exs`. The capture is kept as a guard, not because
    # a line is expected: today the kill produces no report at all (measured 0
    # bytes, standalone and in the full suite), but if the runtime ever logged
    # one it must not land in the suite's output.
    capture_log(fn ->
      Process.exit(coordinator, :kill)
      Eventually.eventually(fn -> not Process.alive?(coordinator) end, timeout: 500)

      # The parent was told the aggregate is not coming...
      assert [notice] = await_message(parent_pid, "stopped before reporting its aggregate")
      assert notice =~ "will arrive as messages instead"

      cast_child_completed(parent_pid, child0, "alpha-done")

      # ...and the children's own answers still arrive: with the reporting
      # target gone, delivery falls back to the parent's inbox.
      assert [message] = await_message(parent_pid, "alpha-done")
      assert message =~ ~s([Message from agent "#{child0}"])
    end)
  end

  test "a timeout under max_concurrency 1 does not drop the unspawned items", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    # One child at a time, so the first item's deadline passes while the rest are
    # still unspawned. A finish triggered by "nothing is pending" here would drop
    # them: their slots would go out as "no result" and their children would
    # never exist.
    run_batch(parent_pid, "call_batch_paced", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"],
      "timeout" => 1,
      "max_concurrency" => 1
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    child_names = collect_child_names(parent_name, 3)

    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

    # All three items were spawned, one at a time, despite the first deadline
    # passing immediately.
    assert child_names == ["alpha", "beta", "gamma"]

    assert [first, second, third] = await_aggregate(parent_pid, "timed out after")
    assert first =~ "timed out after 1ms"
    assert second =~ "timed out after 1ms"
    assert third =~ "timed out after 1ms"

    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}
  end

  test "a fail_fast stop reports the slots the batch filled before it", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_partial", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"],
      "on_error" => "fail_fast"
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1, child2] = collect_child_names(parent_name, 3)

    on_exit(fn ->
      Enum.each([child0, child1, child2], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # alpha answers before beta fails, so its answer is in the batch's slots when
    # fail_fast stops the rest.
    cast_child_completed(parent_pid, child0, "alpha-done")
    assert :ok = Supervisor.stop_agent(space_id, child1)

    assert [report] = await_message(parent_pid, "Batch of 3 stopped")
    assert report =~ "item 1 failed"
    assert report =~ "stopped before it answered"

    # The rest were stopped, not left running.
    assert Machine.pending_children(:sys.get_state(parent_pid).live.machine) == %{}

    # The already-filled slot goes with the notice — a child's answer is not
    # discarded along with the batch — and the slot the stop never reached says
    # so rather than looking like a child that simply produced nothing.
    assert report =~ ~s(["alpha-done",)
    assert report =~ "not run: the batch stopped"
  end

  test "a Stop kills the batch coordinator, so no further children spawn", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_stop", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"],
      "max_concurrency" => 1
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0] = collect_child_names(parent_name, 1)

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, child0) end)

    coordinator = batch_target(parent_pid, child0)
    assert is_pid(coordinator)
    ref = Process.monitor(coordinator)

    # The batch's own turn is over by now (the tool returned its confirmation),
    # so put the parent back in a busy phase: `{:stop, …}` on an idle agent is a
    # no-op, and the stop transition's coordinator kill is what is under test.
    _ = await_idle(parent_pid)
    set_status(parent_pid, :streaming)
    :ok = Agent.stop_chat(parent_pid)

    # The stop reaches the coordinator: it dies with the turn, before it can
    # spawn the remaining items. Nothing else spawns them, so its death is the
    # deterministic proof that no further child can appear — a bounded
    # `refute_receive` would only add wall time to the gate. This interleaving
    # has the coordinator parked in `drain` (one child running, concurrency 1);
    # the one where its next request is *already sent* is the next test.
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 500
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "beta")
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "gamma")

    # The stop cleared the children map before the coordinator's DOWN, so the
    # parent does not report a lost batch — it asked for the stop — and no
    # aggregate arrives.
    state = await_idle(parent_pid)
    assert state.live.machine.children == %Children{}
    assert delivered_texts(state, "stopped before reporting its aggregate") == []
    assert delivered_texts(state, "Message from agent") == []
  end

  test "a spawn request already in flight when the Stop lands is refused", %{vid: vid} do
    {parent_pid, _parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    # The interleaving a Stop creates, made deterministic: the stop is in the
    # parent's mailbox *before* the coordinator's first spawn request, so the
    # parent processes the stop first — and the request, which the coordinator
    # sent before the stop's kill reached it, is still ahead of the stop
    # timer's message (mailbox order), i.e. it is processed while the phase is
    # `:stopping`.
    #
    # The batch's own turn is over by now, so put the parent back in a busy
    # phase first: `{:stop, …}` on an idle agent is a no-op.
    state = await_idle(parent_pid)
    set_status(parent_pid, :streaming)
    :sys.suspend(parent_pid)
    send(parent_pid, {:chat_stopped, self()})

    # The batch is launched while the parent is suspended, so its request cannot
    # be handled before the stop.
    ctx = %{Turn.build_ctx(state) | agent_pid: parent_pid}
    tc = %ToolCall{name: "agents-batch", arguments: %{"items" => ["alpha", "beta"]}}

    assert {:ok, confirmation} = BatchCoordinator.run(ctx, tc)
    assert confirmation =~ "Fanned 2 item(s)"

    # Wait until the coordinator's request is in the mailbox (the stop plus the
    # request), then let the parent run.
    assert Eventually.eventually(fn -> queued_messages(parent_pid) >= 2 end, timeout: 500)

    :sys.resume(parent_pid)

    # The stop was processed first and the request was refused: nothing was
    # spawned, nothing was started, and the parent was not told a batch was lost
    # (it asked for the stop) — and the coordinator did not report a spawn
    # failure it did not have.
    state = await_idle(parent_pid)
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "alpha")
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "beta")
    assert state.live.machine.children == %Children{}
    assert delivered_texts(state, "stopped before reporting its aggregate") == []
    assert delivered_texts(state, "Batch of 2 stopped") == []
  end

  test "a full peer inbox does not refuse the batch aggregate", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_full_inbox", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn ->
      Enum.each([child0, child1], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # Hold the parent busy (its own turn is over), then fill its queue to the
    # peer cap.
    _ = await_idle(parent_pid)
    set_status(parent_pid, :streaming)

    Enum.each(1..100, fn n ->
      assert {:ok, :queued} = Agent.deliver_message(parent_pid, "peer-#{n}", "queued #{n}")
    end)

    # A peer's message is refused at the cap — which is what the aggregate's
    # delivery would hit through `Agent.deliver_message/4`, losing the batch.
    assert {:error, :inbox_full} = Agent.deliver_message(parent_pid, "peer", "one too many")

    cast_child_completed(parent_pid, child0, "alpha-done")
    cast_child_completed(parent_pid, child1, "beta-done")

    aggregate =
      Eventually.eventually(
        fn ->
          :sys.get_state(parent_pid).live.inbox
          |> Enum.find_value(fn entry ->
            if entry.content =~ "alpha-done", do: entry.content
          end)
        end,
        timeout: 500
      )

    assert aggregate =~ ~s(["alpha-done","beta-done"])

    # It is queued, not refused and not lost: the parent's transcript does not
    # have it yet, and it sits behind the 100 peers in the queue.
    state = :sys.get_state(parent_pid)
    assert List.last(state.live.inbox).content == aggregate
    assert delivered_texts(state, "alpha-done") == []

    reset_to_idle(parent_pid)
  end

  # ---- helpers ----

  # The parent's queued-message count, for a test that has to know a request is
  # already in its mailbox before releasing it.
  defp queued_messages(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} -> count
      _other -> 0
    end
  end

  defp batch_target(parent_pid, child_name) do
    Children.target(:sys.get_state(parent_pid).live.machine.children, child_name)
  end

  # Start a parent agent whose `Agents.chat/3` is stubbed (children don't run a
  # real chat cycle) and allow the coordinator to call the stub.
  defp start_batch_parent(vid) do
    {parent_pid, parent_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    Mimic.allow(Agents, self(), parent_pid)
    {parent_pid, parent_name}
  end

  # Queue a tool call as the model's first response and a final text response,
  # then kick off the parent's chat turn. (The turns the delivered messages
  # start answer with MockClient's random fallback: this test is about the
  # batch's own messages.)
  defp run_batch(parent_pid, id, args) do
    MockClient.set_tool_response(%{
      text: "batching",
      tool_calls: [%{id: id, name: "agents-batch", arguments: args}]
    })

    MockClient.set_response("parent final")
    :ok = Agent.chat(parent_pid, "batch a thing")
  end

  # Wait until the parent has delivered a message containing `needle` and
  # finished the turn that delivery started, so no background process touches
  # the sandbox after the test ends. Returns every matching text.
  defp await_message(parent_pid, needle) do
    Eventually.eventually(
      fn ->
        state = :sys.get_state(parent_pid)

        case {Machine.status_for(state.live.machine), delivered_texts(state, needle)} do
          {:idle, [_ | _] = texts} -> texts
          _ -> nil
        end
      end,
      timeout: 1_000
    )
  end

  # Wait until the parent is idle (its turn is over), so a test that pokes its
  # state cannot race the turn's own transitions. Returns the state.
  defp await_idle(parent_pid) do
    Eventually.eventually(
      fn ->
        state = :sys.get_state(parent_pid)
        if Machine.status_for(state.live.machine) == :idle, do: state
      end,
      timeout: 1_000
    )
  end

  # Fabricate a busy phase for a test that needs the parent busy at a moment the
  # machine cannot be driven to. `status_to_machine/2` is the test-support
  # mapping the inbox tests use.
  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | machine: Machine.status_to_machine(state.live.machine, status)
          }
      }
    end)
  end

  # Undo a fabricated busy status and the queue a test filled, so the agent is
  # idle (and empty) for the teardown.
  defp reset_to_idle(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | inbox: [],
              machine: Machine.status_to_machine(state.live.machine, :idle)
          }
      }
    end)
  end

  # The aggregate message, JSON-decoded: the delivered text carries the
  # delivery's `[mode: …]` prefix on its own line.
  defp await_aggregate(parent_pid, needle) do
    [message] =
      await_message(parent_pid, needle)
      |> tap(fn texts ->
        assert length(texts) == 1, "expected one aggregate, got: #{inspect(texts)}"
      end)

    json = message |> String.split("\n") |> List.last()

    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, reason} -> flunk("not JSON: #{inspect(message)} (#{inspect(reason)})")
    end
  end

  defp delivered_texts(state, needle) do
    for {:user, %{parts: parts}} <- state.chat_state.messages,
        %Part.Text{text: text} <- parts,
        text =~ needle,
        do: text
  end

  defp batch_tool_result(parent_state) do
    {:tool, %{parts: [%Part.ToolResult{name: "agents-batch"} = result]}} =
      Enum.find(parent_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-batch"}, &1))

        _ ->
          false
      end)

    result
  end

  # Collect `count` `agent:created` broadcasts for `parent_name`, in the order
  # they arrive (item order). Non-matching broadcasts from concurrent tests are
  # filtered by the `parentName` guard. There is no synchronous point to wait on
  # here: `Agent.chat/2` only casts, and the broadcast is emitted by the parent
  # while it handles a `{:spawn_agent_request, ...}` call from the coordinator
  # task, which is itself spawned a few hops later. So the fence is a real
  # (bounded) wait, and the timeout is PER CHILD: a 3-item batch can spend up to
  # 3x this. 1s is a wide margin — the whole file runs in well under a second.
  defp collect_child_names(_parent_name, 0, acc), do: Enum.reverse(acc)

  defp collect_child_names(parent_name, n, acc) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:created",
                     payload: %{"name" => name, "parentName" => ^parent_name}
                   },
                   1_000

    collect_child_names(parent_name, n - 1, [name | acc])
  end

  defp collect_child_names(parent_name, n), do: collect_child_names(parent_name, n, [])

  # Cast a child's completion to the parent, mimicking the child's idle
  # completion in production.
  defp cast_child_completed(parent_pid, child_name, response) do
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

  # `archive` defaults to true, so `handle_child_completed/4` archives each
  # child as the parent processes its completion. The DB `archived` flag is set
  # synchronously in that path, so it's a deterministic proof that archiving ran
  # (no liveness polling / DOWN waits).
  defp assert_children_archived(space_id, names) do
    Enum.each(names, fn name ->
      {:ok, row} = Nest.Persistence.fetch_agent(space_id, name)
      assert row.archived == true, "child #{name} should be marked archived in the DB"
    end)
  end

  defp stub_child_chat do
    Mimic.copy(Agents)
    Mimic.stub(Agents, :chat, fn _space_id, _name, _content -> :ok end)
  end

  # The coordinator's vocation exposes `agents-batch`. Children inherit this
  # vocation (`vocation_id` is omitted in the call), which is fine: their chat
  # cycle is stubbed.
  defp upsert_batch_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "AgentsBatch #{System.unique_integer([:positive])}",
        description: "End-to-end agents-batch test",
        system_prompt: "Batch work over items.",
        tools: ["context", "agents"],
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
