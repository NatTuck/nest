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
  import Nest.Agents.AgentsBatchTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchCoordinator
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Messages.ToolCall

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
    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())

    # The coordinator spawns children in item order (sequential `pace`), so the
    # creation broadcasts arrive in item order. Collect all three, filtered by
    # parent so a concurrent test's broadcast can't match.
    child_names = collect_child_names(parent_name, 3)

    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

    # Children are named from their item (no prefix here), not by the
    # adjective-generator.
    assert child_names == ["alpha", "beta", "gamma"]

    # The tool result is the confirmation, not the aggregate: nothing waited.
    confirmation = batch_tool_result(Agent.get_messages(parent_pid, 1_000)).content
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

    # allowlist: snapshot — messages + pending_children + descendant_usage
    parent_state = :sys.get_state(parent_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(parent_state.chat_state.messages)

    # The children report to the coordinator, so the parent reads the batch
    # once: the aggregate is the only batch traffic in its transcript.
    assert delivered_texts(parent_state.chat_state.messages, "Message from agent") == []

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

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
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

    assert Agent.get_pending_children(parent_pid, 1_000) == %{}
  end

  test "a child that dies before responding fails its slot and is not archived", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_die", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
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

    assert Agent.get_pending_children(parent_pid, 1_000) == %{}

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

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    [_child0, _child1] = collect_child_names(parent_name, 2)

    assert [first, second] = await_aggregate(parent_pid, "timed out after")
    assert first =~ "timed out after 1ms"
    assert second =~ "timed out after 1ms"
    assert Agent.get_pending_children(parent_pid, 1_000) == %{}
  end

  test "a timed-out item under fail_fast stops the rest and reports it", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)

    run_batch(parent_pid, "call_batch_fail_fast", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"],
      "timeout" => 1,
      "on_error" => "fail_fast"
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    [_child0, _child1] = collect_child_names(parent_name, 2)

    # The confirmation promises exactly what fail_fast does, before anything
    # fails: it stops at the first failure and reports the slots it filled.
    confirmation = batch_tool_result(Agent.get_messages(parent_pid, 1_000)).content
    assert confirmation =~ "stops at the first failure"
    assert confirmation =~ "reports the slots it filled before it stopped"

    # fail_fast reports the stop in the inbox rather than as a tool result: the
    # call had already returned its confirmation when the deadline passed.
    assert [report] = await_message(parent_pid, "stopped:")
    assert report =~ "Batch of 2 stopped: an item timed out after 1ms"

    assert Agent.get_pending_children(parent_pid, 1_000) == %{}
  end

  test "a batch whose coordinator dies falls back to per-child messages", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_orphan", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn -> Enum.each([child0, child1], &Supervisor.stop_agent(space_id, &1)) end)

    coordinator = batch_target(parent_pid, child0)
    assert is_pid(coordinator)

    # The parent's own turn must be over before the coordinator dies. Which arm
    # of `notice_lost_batch/3`'s `if` runs depends on whether the machine is
    # `:idle` when the `:DOWN` is handled, and a parent still mid-turn takes the
    # other one — so without this fence the file's coverage of those two arms
    # jitters with the seed. `get_status/2` is a call, so `:idle` here is a
    # happens-after fence on the parent's own loop rather than a clock. (The
    # `chat:status` frame is not usable for it: an `idle` frame from the turn
    # that started the batch could still be in the mailbox.)
    assert Eventually.eventually(fn -> Agent.get_status(parent_pid, 500) == :idle end,
             timeout: 500
           )

    # A `:kill`ed task never runs the coordinator's rescue, so there is no
    # coordinator line to assert here — its own report is asserted in
    # `batch_coordinator_test.exs`. The capture is kept as a guard, not because
    # a line is expected: today the kill produces no report at all (measured 0
    # bytes, standalone and in the full suite), but if the runtime ever logged
    # one it must not land in the suite's output.
    capture_log(fn ->
      # The kill is asynchronous, so fence on the task's own death — the
      # `:DOWN` of a monitor installed *before* the kill, so it cannot be
      # missed — rather than polling `Process.alive?/1` for it.
      ref = Process.monitor(coordinator)
      Process.exit(coordinator, :kill)
      assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 1_000

      # The parent was told the aggregate is not coming...
      assert [notice] = await_message(parent_pid, "stopped before reporting its aggregate")
      assert notice =~ "will arrive as messages instead"

      cast_child_completed(parent_pid, child0, "alpha-done")

      # ...and the children's own answers still arrive: with the reporting
      # target gone, delivery falls back to the parent's inbox.
      assert [message] = await_message(parent_pid, "alpha-done")
      assert message =~ ~s([From agent #{child0} | mode: act])
    end)
  end

  test "a lost batch noticed while the parent is busy is queued, not drained", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_busy_orphan", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn -> Enum.each([child0, child1], &Supervisor.stop_agent(space_id, &1)) end)

    coordinator = batch_target(parent_pid, child0)
    assert is_pid(coordinator)

    # The other arm of `notice_lost_batch/3`'s `if`, made deterministic: the
    # parent's turn is over, then it is held in a busy phase, so the
    # coordinator's `:DOWN` is handled while the machine is NOT idle. The two
    # arms used to be a coin flip per run (whichever the seed's ordering picked
    # left the other uncovered).
    assert Eventually.eventually(fn -> Agent.get_status(parent_pid, 500) == :idle end,
             timeout: 500
           )

    set_status(parent_pid, :streaming)

    # A peer's message waiting in the queue is what a drain would deliver, so it
    # is the evidence for whether the drain ran.
    assert {:ok, :queued} = Agent.deliver_note(parent_pid, "peer-1", "queued while busy")

    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 500

    # The notice lands *behind* the peer's message: the parent is told the
    # aggregate is not coming, and the queue is left for its own next boundary.
    # The count is the fence — nothing else in this test queues an entry, so the
    # second `chat_inbox` frame is the one `notice_lost_batch/3` appended.
    assert_receive {:chat_inbox, %{count: 2}}, 500

    # allowlist: snapshot — inbox + messages
    state = :sys.get_state(parent_pid, 500)
    queued = Enum.map(state.live.inbox, & &1.content)
    assert Enum.any?(queued, &(&1 =~ "queued while busy"))
    assert Enum.any?(queued, &(&1 =~ "stopped before reporting its aggregate"))

    # Not delivered: a busy agent is not drained mid-turn, so the peer's message
    # is still in the queue rather than in the transcript.
    assert delivered_texts(state.chat_state.messages, "queued while busy") == []

    reset_to_idle(parent_pid)
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

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    child_names = collect_child_names(parent_name, 3)

    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

    # All three items were spawned, one at a time, despite the first deadline
    # passing immediately.
    assert child_names == ["alpha", "beta", "gamma"]

    assert [first, second, third] = await_aggregate(parent_pid, "timed out after")
    assert first =~ "timed out after 1ms"
    assert second =~ "timed out after 1ms"
    assert third =~ "timed out after 1ms"

    assert Agent.get_pending_children(parent_pid, 1_000) == %{}
  end

  test "a fail_fast stop reports the slots the batch filled before it", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_partial", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"],
      "on_error" => "fail_fast"
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
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
    assert Agent.get_pending_children(parent_pid, 1_000) == %{}

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

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
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
    assert_receive {:DOWN, ^ref, :process, ^coordinator, :killed}, 1_000
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "beta")
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "gamma")

    # The stop cleared the children map before the coordinator's DOWN, so the
    # parent does not report a lost batch — it asked for the stop — and no
    # aggregate arrives.
    state = await_idle(parent_pid)
    assert state.live.machine.children == %Children{}
    messages = state.chat_state.messages
    assert delivered_texts(messages, "stopped before reporting its aggregate") == []
    assert delivered_texts(messages, "Message from agent") == []
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
    # No turn runs here (the coordinator's run below is fabricated), so no idle
    # `chat:status` frame will ever arrive: read the already-idle state directly.
    # allowlist: harness — Turn.build_ctx/1's argument
    state = :sys.get_state(parent_pid, 1_000)
    set_status(parent_pid, :streaming)
    # Explicit timeouts on both: `:sys.suspend/1` and `:sys.resume/1` otherwise
    # rely on OTP's implicit 5 s ack deadline, which is over the `#21` cap. They
    # get the cap rather than the 1 s the `:sys.get_state` reads use, because
    # they *change* the process's system state (a timeout here is a broken test,
    # not a slow read) and because the ack is handled ahead of the mailbox.
    :sys.suspend(parent_pid, 2_000)
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

    :sys.resume(parent_pid, 2_000)

    # The stop was processed first and the request was refused: nothing was
    # spawned, nothing was started, and the parent was not told a batch was lost
    # (it asked for the stop) — and the coordinator did not report a spawn
    # failure it did not have.
    state = await_idle(parent_pid)
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "item-1")
    assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, "item-2")
    assert state.live.machine.children == %Children{}
    messages = state.chat_state.messages
    assert delivered_texts(messages, "stopped before reporting its aggregate") == []
    assert delivered_texts(messages, "Batch of 2 stopped") == []
  end

  test "a full peer inbox does not refuse the batch aggregate", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_full_inbox", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, space_topic())
    [child0, child1] = collect_child_names(parent_name, 2)

    on_exit(fn ->
      Enum.each([child0, child1], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # Hold the parent busy (its own turn is over), then fill its queue to the
    # peer cap.
    _ = await_idle(parent_pid)
    set_status(parent_pid, :streaming)

    Enum.each(1..100, fn n ->
      assert {:ok, :queued} = Agent.deliver_note(parent_pid, "peer-#{n}", "queued #{n}")
    end)

    # A peer's message is refused at the cap — which is what the aggregate's
    # delivery would hit through `Agent.deliver_note/4`, losing the batch.
    assert {:error, :inbox_full} = Agent.deliver_note(parent_pid, "peer", "one too many")

    cast_child_completed(parent_pid, child0, "alpha-done")
    cast_child_completed(parent_pid, child1, "beta-done")

    # The aggregate's own arrival: `Agent.deliver_internal/4` never refuses, so
    # its entry lands in the queue behind the 100 peers and the inbox broadcast
    # that carries it is the event — the only frame in this test past the cap
    # the refusal above pinned.
    assert_receive {:chat_inbox, %{count: count}} when count > 100, 1_000

    # allowlist: snapshot — inbox + messages
    state = :sys.get_state(parent_pid, 1_000)

    aggregate_entry =
      Enum.find(state.live.inbox, fn entry -> entry.content =~ "alpha-done" end)

    assert aggregate_entry.content =~ ~s(["alpha-done","beta-done"])

    # Its sender is `nil`, not a name: the aggregate is the runtime's own
    # result, so no agent frames it and no row has to resolve a synthetic
    # "agents-batch".
    assert aggregate_entry.from == nil

    # It is queued, not refused and not lost: the parent's transcript does not
    # have it yet, and it sits behind the 100 peers in the queue.
    assert List.last(state.live.inbox).content == aggregate_entry.content
    assert delivered_texts(state.chat_state.messages, "alpha-done") == []

    reset_to_idle(parent_pid)
  end
end
