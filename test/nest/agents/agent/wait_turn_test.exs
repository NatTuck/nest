defmodule Nest.Agents.Agent.WaitTurnTest do
  @moduledoc """
  The turn-level half of issue #54: a wait tool's batch **ends the caller's
  turn**.

  `WatchTest` covers the registration, the notice, and the watcher's lifetime;
  `WaitForIdleTest` covers the wait engine. This file covers what the machine
  does with a wait's result:

    * it rests the turn in `:idle` instead of iterating — no further LLM
      request is made — while an ordinary tool batch still iterates;
    * it appends the result and the synthetic acknowledgement in an order that
      leaves the wire valid (the result is a wire-`user` message, so an idle
      agent would otherwise rest on a user role);
    * a message that is already queued is never stranded, and never delivered
      through a transient `:idle` either: the rest's own drain keeps the turn
      going for it, and a batch that is still interruptible never reaches the
      rest at all — the batch-start deferral (issue #103) delivers the message
      by backgrounding the batch, and the wait's real result then arrives as a
      message;
    * the watched event wakes the idle agent with a message.

  Both tools are driven end to end: `agents-wait` against a stubbed space
  listing, `shell-wait` against a real background job.
  """
  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTurnTestHelpers
  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.ToolResult
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools.ShellCmd
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    # Both wait tools registered: `shell-wait` is a regular tool, so it has to
    # be in the agent's own tool list to run at all.
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "WaitTurn #{System.unique_integer([:positive])}",
        description: "Wait tools for the turn-level tests",
        system_prompt: "Wait for peers in this space.",
        tools: ["context", "agents", "shell"],
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    {pid, name} =
      AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: vid})

    %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
  end

  defp agent(name, status), do: %{name: name, status: status}

  # Drive `list_agents_info_for_space/1` from a FIFO of snapshots; the last
  # sticks. The wait reads it once to resolve, once more from the watcher's
  # reference read, once for the watcher's authoritative read, and again on
  # each event it is woken by.
  #
  # The stub is private to this test process, and the readers are the agent's
  # tool worker and the watcher task, so the agent is allowed explicitly: both
  # carry the agent in their `$callers` chain, which is what Mimic resolves
  # ownership through.
  #
  # `park: :first` parks the *first* read — the tool worker's own `resolve` —
  # so a test can act while the batch is executing; every later read is served
  # normally.
  defp stub_listing(pid, frames, opts \\ []) do
    id = {:wait_turn_listing, System.unique_integer([:positive])}
    queue = start_supervised!({Elixir.Agent, fn -> frames end}, id: id)
    test_pid = self()
    reads = :counters.new(1, [])
    park? = Keyword.get(opts, :park) == :first

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      :counters.add(reads, 1, 1)

      if park? and :counters.get(reads, 1) == 1,
        do: park(test_pid, :listing_read, :release_listing)

      Elixir.Agent.get_and_update(queue, &next_listing/1)
    end)

    Mimic.allow(Nest.Agents, self(), pid)
  end

  defp next_listing([last]), do: {last, [last]}
  defp next_listing([head | rest]), do: {head, rest}

  # Wait for the agent to settle, on the frame that decides it: the `idle`
  # broadcast that ends the turn. A bare `idle` frame is not the fence — a stop,
  # and any turn end that drains, publishes the transient
  # `streaming -> idle -> streaming` of issue #15 first — so the fence is the
  # idle that carries an empty queue. An empty queue is also exactly the state
  # no further drain can start from; the status read that follows is a read of
  # the settled state, not a wait.
  defp await_idle(pid) do
    assert_receive {:chat_status, %{status: "idle", pendingMessageCount: 0}}, 1_000

    assert Agent.get_public_info(pid, 1_000).status == :idle
  end

  defp messages(pid), do: Agent.get_messages(pid, 1_000)

  # The result a planted backgrounded batch delivers: the shape #36's late
  # delivery carries (`BatchSizer`'s own `ToolResult`), whose rendering is the
  # notice body.
  defp other_result do
    %ToolResult{
      tool_call_id: "other",
      name: "shell-cmd",
      content: "backgrounded output",
      is_error: false
    }
  end

  defp wait_tool_call(id, args), do: %{id: id, name: "agents-wait", arguments: args}

  # The acknowledgement the machine appends after a wait's result, as text.
  defp waiting_ack_text do
    {:assistant, %Assistant{parts: [%Part.Text{text: text}]}} = MessageList.waiting_ack()
    text
  end

  describe "the machine's rule" do
    test "a wait result rests the turn; an ordinary result still iterates" do
      # The machine tells the two apart by the result's `state` — the marker
      # the tool layer stamps for a call that registered a watch — and never by
      # the tool's name, so the action vocabulary and the decision stay here.
      ctx = %{ctx() | messages: [system_message(), assistant_with_tool_use()]}

      wait = %ToolResult{
        tool_call_id: "call_1",
        name: "agents-wait",
        content: "Watching (you will be notified): bob.",
        is_error: false,
        state: "waiting"
      }

      machine = state_at(:executing_tools, ctx: ctx)

      {:ok, actions, next} =
        Machine.step(machine, {:tool_results, machine.work.worker_ref, [wait]})

      # `:iterate` is what keeps a turn going; a wait rest emits the rest
      # instead, and rests the machine in `:idle` with no worker.
      refute :iterate in actions

      assert Enum.map(actions, &action_tag/1) == [
               :append,
               :record_file_access,
               :append,
               :finalize,
               :drain_inbox
             ]

      assert {:finalize, :waiting} in actions
      assert next.phase == :idle
      assert next.work.worker_ref == nil
      assert next.work.worker_kind == nil

      # A queued message keeps the turn going instead: the machine stays in
      # `:generating`, no `{:finalize, …}` runs (nothing is over), and the
      # drain starts the delivered message's turn in place — so the message is
      # neither stranded nor delivered through a transient `:idle`.
      queued_ctx = Map.put(ctx, :inbox_count, 1)
      machine = state_at(:executing_tools, ctx: queued_ctx)

      {:ok, actions, next} =
        Machine.step(machine, {:tool_results, machine.work.worker_ref, [wait]})

      assert Enum.map(actions, &action_tag/1) == [
               :append,
               :record_file_access,
               :append,
               :drain_inbox
             ]

      refute Enum.any?(actions, &match?({:finalize, _}, &1))
      assert next.phase == :generating

      # An ordinary batch is untouched: it appends and iterates.
      ordinary = %ToolResult{
        tool_call_id: "call_1",
        name: "shell-cmd",
        content: "ok",
        is_error: false
      }

      machine = state_at(:executing_tools, ctx: ctx)

      {:ok, actions, next} =
        Machine.step(machine, {:tool_results, machine.work.worker_ref, [ordinary]})

      assert Enum.map(actions, &action_tag/1) == [:append, :record_file_access, :iterate]
      assert next.phase == :generating
    end
  end

  describe "agents-wait" do
    test "ends the turn, appending the result and its acknowledgement", %{pid: pid, name: name} do
      stub_listing(pid, [[agent(name, :idle), agent("bob", :streaming)]])

      MockClient.set_tool_response(%{
        text: "waiting",
        tool_calls: [wait_tool_call("w1", %{"names" => ["bob"]})]
      })

      # The response a *second* request would consume. It must still be queued
      # when the turn ends.
      MockClient.set_response("this must never be requested")

      :ok = Agent.chat(pid, "wait for bob")
      await_idle(pid)

      # The turn is over: no worker, and the live working set cleared by
      # `{:finalize, :waiting}` (the streaming accumulator is the observable
      # part of it).
      assert %{worker_ref: nil, active_worker: nil, worker_kind: nil} =
               Agent.get_work(pid, 1_000)

      assert Agent.get_public_info(pid, 1_000).partial == nil

      # The result and the synthetic acknowledgement, in that order: the result
      # is a wire-`user` message, so resting on it alone would leave the idle
      # agent on a user role.
      msgs = messages(pid)

      assert [{:tool, tool_msg}, {:assistant, ack}] = Enum.take(msgs, -2)

      assert [
               %Part.ToolResult{
                 name: "agents-wait",
                 state: "waiting",
                 is_error: false,
                 content: content
               }
             ] =
               tool_msg.parts

      assert content =~ "Watching (you will be notified): bob"
      assert Enum.map(ack.parts, & &1.text) == [waiting_ack_text()]

      # ...which is what leaves the wire valid: pairing and alternation hold,
      # and the idle agent rests on an assistant.
      assert Preflight.validate(msgs) == :ok
      assert MessageList.last_wire_role(msgs) == :assistant

      # No further request was made: the queued response is untouched.
      assert MockClient.take_pending(pid) == [{:text, "this must never be requested"}]
    end

    test "a message queued before the batch starts is delivered, not stranded", %{
      pid: pid,
      name: name
    } do
      stub_listing(pid, [[agent(name, :idle), agent("bob", :streaming)]])

      MockClient.set_tool_response(%{
        text: "waiting",
        tool_calls: [wait_tool_call("w1", %{"names" => ["bob"]})]
      })

      MockClient.set_response("the queued message's turn")
      MockClient.set_response("the notice's turn")

      :ok = Agent.chat(pid, "wait for bob")

      # Queued, not delivered: the first message left the agent streaming, so
      # this one lands on the inbox. It arrives *before* the batch exists, so
      # the streaming arm queues it and the batch-start deferral (issue #103)
      # is what delivers it — by moving the wait's batch to the background, not
      # by the wait rest. Either way the message is delivered and the wait's
      # own result follows it as a message, which is what this test pins.
      :ok = Agent.chat(pid, "queued while busy")

      notice = await_delivery("Your backgrounded command (agents-wait)")
      assert notice =~ "Watching (you will be notified): bob"

      await_idle(pid)

      msgs = messages(pid)
      backgrounded = Enum.find_index(msgs, &match?({:tool, _}, &1))

      # The deferral's own shape: the synthetic result answers the wait call and
      # says its real result arrives later, and the ack follows it — the same
      # ordering the wait rest uses, because a `{:tool, _}` is a wire-`user`
      # message either way.
      assert {:tool, synthetic} = Enum.at(msgs, backgrounded)

      assert [%Part.ToolResult{name: "agents-wait", state: "backgrounded", is_error: false}] =
               synthetic.parts

      assert hd(synthetic.parts).content =~ "moved to the background"
      assert text_of(Enum.at(msgs, backgrounded + 1)) =~ "running in the background"

      assert {:user, %{parts: [%Part.Text{text: drained}]}} = Enum.at(msgs, backgrounded + 2)
      assert drained =~ "queued while busy"

      # ...and the real result did arrive, as the notice the deferral promised:
      # the watch was registered and its confirmation is in the transcript, not
      # lost with the backgrounded batch.
      assert Enum.any?(user_texts(msgs), &(&1 =~ "Watching (you will be notified): bob"))
      assert Preflight.validate(msgs) == :ok
      assert Agent.get_public_info(pid, 1_000).pending_messages == []
      assert map_size(Agent.get_watches(pid, 1_000)) == 1
    end

    test "a notice enqueued during the wait's batch is delivered by the rest's drain", %{
      pid: pid,
      name: name
    } do
      # The one route left to the rest's drain rule: an *in-process* enqueue
      # while the batch executes. A peer's or a human's message arriving here is
      # backgrounded by the arrival path (issue #36), and one queued before the
      # batch by the batch-start deferral (issue #103) — neither reaches the
      # wait rest. `Inbox.enqueue_internal/5` (a backgrounded batch's outcome)
      # asks neither, so its entry is still queued when the wait's result lands.
      #
      # The batch's worker is parked inside the wait tool's own listing read, so
      # the notice lands deterministically while the batch executes. The
      # backgrounded entry is planted — a batch with a live worker of its own is
      # #36's subject, not this rule's — and everything from the enqueue on is
      # the real path.
      stub_listing(pid, [[agent(name, :idle), agent("bob", :streaming)]], park: :first)

      MockClient.set_tool_response(%{
        text: "waiting",
        tool_calls: [wait_tool_call("w1", %{"names" => ["bob"]})]
      })

      MockClient.set_response("the notice's turn")

      :ok = Agent.chat(pid, "wait for bob")
      assert_receive {:listing_read, worker}, 1_000

      # The settle that records the batch's worker has finished — the deferral
      # read an empty queue and did nothing — so the notice cannot be raced by
      # it. `get_public_info/2` is a synchronous read, so it is the barrier; the
      # status it reports is the one the notice needs.
      assert Agent.get_public_info(pid, 1_000).status == :executing_tools

      ref = make_ref()

      # The backgrounded batch whose outcome is enqueued: planted, because a
      # batch with a live worker of its own is #36's subject, not this rule's.
      :sys.replace_state(
        pid,
        fn state ->
          put_in(state.live.machine.work.backgrounded, %{ref => %{pid: self(), ids: ["other"]}})
        end,
        1_000
      )

      send(pid, {:tool_results, ref, [other_result()]})

      # Queued, not delivered: the machine is `:executing_tools`, and the
      # backgrounded path only drains from `:idle`.
      assert_receive {:chat_inbox, %{count: 1}}, 1_000

      send(worker, :release_listing)

      # The wait's result lands with the notice still queued, so the rest's
      # drain delivers it — *in place*. No `idle` frame before the notice's own
      # turn is what tells this apart from resting first and draining from
      # `:idle`, which would publish `idle -> streaming` here.
      assert statuses_until_idle(name) == ["streaming", "executing_tools", "streaming", "idle"]

      msgs = messages(pid)

      waiting =
        Enum.find_index(
          msgs,
          &match?({:tool, %{parts: [%Part.ToolResult{state: "waiting"}]}}, &1)
        )

      assert {:assistant, _ack} = Enum.at(msgs, waiting + 1)

      assert {:user, %{parts: [%Part.Text{text: drained}]}} = Enum.at(msgs, waiting + 2)
      assert drained =~ "backgrounded output"

      assert Agent.get_public_info(pid, 1_000).pending_messages == []
    end

    test "the watched event wakes the idle agent with a message", %{pid: pid, name: name} do
      stub_listing(pid, [
        # resolve: the target is busy, so a watch is registered
        [agent(name, :idle), agent("bob", :streaming)],
        # the watcher's reference read, then its authoritative read: still busy
        [agent(name, :idle), agent("bob", :streaming)],
        [agent(name, :idle), agent("bob", :streaming)],
        # the recheck the target's status frame drives: bob is idle now
        [agent(name, :idle), agent("bob", :idle)]
      ])

      MockClient.set_tool_response(%{
        text: "waiting",
        tool_calls: [wait_tool_call("w1", %{"names" => ["bob"]})]
      })

      MockClient.set_response("woken")
      :ok = Agent.chat(pid, "wait for bob")
      await_idle(pid)

      # The target's own status frame — the event the wait is woken by. It is
      # delivered to the watcher task directly rather than broadcast: the
      # watcher subscribes inside its own task, so a broadcast sent from here
      # could land before that subscription, while a direct frame waits in the
      # task's mailbox for the loop that matches it.
      [{_ref, %{pid: task}}] = Map.to_list(Agent.get_watches(pid, 1_000))
      send(task, {:chat_status, %{status: "idle"}})

      # The notice starts a turn of its own: the user-message broadcast is the
      # event that says it landed.
      assert_receive {:chat_message, {:user, _}}, 1_000
      await_idle(pid)

      notices =
        for {:user, %{parts: parts}} <- messages(pid), %Part.Text{text: text} <- parts, do: text

      assert Enum.any?(notices, &(&1 =~ "Agents now idle: bob. Still busy: (none)."))
      assert Agent.get_watches(pid, 1_000) == %{}
    end
  end

  describe "shell-wait" do
    test "ends the turn too", %{pid: pid, name: name, space_id: space_id} do
      # The agent's own scratch directory — the space dir plus the bare agent
      # name (`TmpSpace`'s layout) — so the job's log lives where the agent's
      # own `shell-list` would find it.
      scratch = Path.join(TmpSpace.space_dir(space_id), name)
      workspace = Agent.get_public_info(pid, 1_000).workspace_path
      key = {space_id, name}

      {:ok, _} =
        ShellCmd.execute("sleep 30", Mounts.new(workspace, scratch), nil,
          background: true,
          agent_key: key,
          grace_ms: 0
        )

      [%{id: job_id}] = ShellJobs.list(key)

      MockClient.set_tool_response(%{
        text: "waiting",
        tool_calls: [%{id: "s1", name: "shell-wait", arguments: %{"id" => job_id}}]
      })

      MockClient.set_response("this must never be requested")

      :ok = Agent.chat(pid, "wait for the job")
      await_idle(pid)

      assert %{worker_ref: nil, active_worker: nil, worker_kind: nil} =
               Agent.get_work(pid, 1_000)

      assert [{:tool, tool_msg}, {:assistant, _ack}] = Enum.take(messages(pid), -2)

      assert [%Part.ToolResult{name: "shell-wait", state: "waiting", is_error: false}] =
               tool_msg.parts

      assert MockClient.take_pending(pid) == [{:text, "this must never be requested"}]
    end
  end
end
