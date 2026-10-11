defmodule Nest.Agents.Agent.TurnBackgroundingTest do
  @moduledoc """
  The backgrounding delivery (issue #36): a message that arrives while a tool
  batch is executing is delivered *now* — the batch moves to the background, its
  calls are answered by the machine's synthetic result, and the turn continues
  with the delivered message. The batch's real result arrives later as a
  message.

  Split out of `Nest.Agents.Agent.TurnAcceptanceTest` (credo's file cap) beside
  the turn driver it drives: these tests need the parked harnesses
  (`park_llm_requests/1` and `park_agent_sends/2`, both in
  `AgentTurnTestHelpers`), which hold every LLM request and the tool worker
  until the test releases them so the transcript and the status sequence at
  each step are reproducible. The last two drive the shapes the first two
  deliberately avoid: a batch whose result arrives only after the turn that
  backgrounded it has ended, and an internal delivery (decision D1).
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Machine

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.ToolResult
  alias Nest.Persistence

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers

  defp seed_loop_count(pid, n) do
    :sys.replace_state(pid, fn state ->
      %{state | live: %{state.live | machine: %{state.live.machine | loop_count: n}}}
    end)
  end

  # The tool worker is parked with `park_agent_sends/2`, which lives in
  # `AgentTurnTestHelpers` (imported above) beside the parked-LLM harness: the
  # same idea — the test decides when the batch's call reaches its target and
  # when the batch returns.

  describe "turn-boundary inbox delivery" do
    test "1.1.9 a self-sent message backgrounds the batch and lands mid-turn, with no idle" do
      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      park_llm_requests(pid)
      park_agent_sends(pid)

      # A turn mid-batch can already be carrying consecutive compactions — the
      # loop breaker's counter is only reset by progress. Seed it, so the reset
      # the synthetic append performs is observable: the synthetic result is a
      # real `:tool` append, so a self-messaging batch counts as progress rather
      # than looking like the loop the breaker exists to break.
      seed_loop_count(pid, 2)

      # Request 1: the model sends *itself* two messages. The first arrives
      # while the batch is executing, so it backgrounds the batch (issue #36)
      # instead of waiting for the turn end.
      MockClient.set_tool_response(%{
        text: "Queueing",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "first"}
          },
          %{
            id: "send_2",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "second"}
          }
        ]
      })

      MockClient.set_response("Done")
      MockClient.set_response("After the notes")

      :ok = Agent.chat(pid, "queue some messages")

      {first, llm1} = next_request()
      assert Enum.any?(user_texts(first), &(&1 =~ "queue some messages"))
      release_llm(llm1)

      # The batch reached the tool worker, which is parked before the first
      # `agents-send`: the agent really is `:executing_tools`.
      assert_receive {:send_blocked, tool}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :executing_tools

      # Release it: the message reaches this same agent, and the batch is
      # backgrounded on it.
      send(tool, :release_send)

      # The worker parks again, before the second `agents-send` — so the batch
      # is *still running* for everything asserted below.
      assert_receive {:send_blocked, ^tool}, 500

      {second, llm2} = next_request()

      mid = :sys.get_state(pid)

      # The delivery did not wait for the batch: the message is in the
      # transcript, answered by the machine's synthetic result and ack, and the
      # turn has moved on to the request that carries it. The synthetic append
      # also reset the compaction loop breaker's counter.
      assert Machine.status_for(mid.live.machine) == :streaming
      assert mid.live.machine.loop_count == 0
      assert mid.live.inbox == []

      assert Enum.map(mid.chat_state.messages, &elem(&1, 0)) ==
               [:system, :user, :assistant, :tool, :assistant, :user]

      synthetic = Enum.at(mid.chat_state.messages, 3)
      ack = text_of(Enum.at(mid.chat_state.messages, 4))
      delivered = text_of(Enum.at(mid.chat_state.messages, 5))

      # The synthetic result answers *every* call of the batch — a partial
      # answer would append fine and fail the turn at the next `:iterate` — and
      # says the real result arrives later.
      assert length(tool_texts(synthetic)) == 2

      assert Enum.all?(
               tool_texts(synthetic),
               &(&1 =~ "moved to the background" and &1 =~ "arrive later as a message")
             )

      # The ack is the machine's own, not the live-bridge alternation ack: it
      # has to say what happened to the call.
      assert ack =~ "running in the background"

      assert delivered == "[mode: chat]\n[Message from agent \"#{name}\"]\nfirst"

      # The request the delivered message rides in on: the synthetic result and
      # the message are already there, before the batch returned.
      assert Enum.any?(user_texts(second), &(&1 =~ "queue some messages"))
      assert Enum.any?(user_texts(second), &(&1 =~ "[Message from agent \"#{name}\"]\nfirst"))
      refute Enum.any?(user_texts(second), &(&1 =~ "second"))

      # The second `agents-send` runs *after* the backgrounding, so this agent
      # is streaming by then and the entry queues behind the delivered one.
      send(tool, :release_send)
      assert_receive {:chat_inbox, %{count: 1}}, 500

      # The batch returns with no live worker to settle it: its real result
      # arrives as a queued notice behind the peer's entry.
      assert_receive {:chat_inbox, %{count: 2}}, 500

      # The turn the delivered message started ends, and the boundary drain
      # delivers the two queued entries as one batch.
      release_llm(llm2)
      {third, llm3} = next_request()
      release_llm(llm3)

      # streaming -> executing_tools -> streaming (the backgrounding) -> idle.
      # The `idle` is the *delivered* turn's end, so no delivery waited for a
      # turn end: an `idle` before that third `streaming` would resolve an
      # idle-based `agents-wait` with the pre-delivery answer and report a
      # partial result to a parent.
      assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]

      # The notice's own turn, which ends the run.
      assert statuses_until_idle() == ["streaming", "idle"]

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
      assert state.live.inbox == []

      # The synthetic result is a real append, so it counts as progress: the
      # compaction loop breaker's counter stays reset (a self-messaging batch
      # terminates instead of looking like a loop).
      assert state.live.machine.loop_count == 0

      messages = state.chat_state.messages

      tool_index = Enum.find_index(messages, &match?({:tool, _}, &1))
      ack_index = Enum.find_index(messages, &(text_of(&1) =~ "running in the background"))
      drained_index = Enum.find_index(messages, &(text_of(&1) =~ "Message from agent"))
      done_index = Enum.find_index(messages, &(text_of(&1) == "Done"))
      late_index = Enum.find_index(messages, &(text_of(&1) =~ "backgrounded command"))
      final_index = Enum.find_index(messages, &(text_of(&1) =~ "After the notes"))

      assert is_integer(tool_index), "expected the synthetic tool result"
      assert is_integer(ack_index), "expected the backgrounding ack"
      assert is_integer(drained_index), "expected the delivered user message"
      assert is_integer(done_index), "expected the response to the request that carried it"
      assert is_integer(late_index), "expected the late result's notice"
      assert is_integer(final_index), "expected the final assistant response"

      # Nothing is interleaved: the synthetic result, its ack, the delivered
      # message, the response to the request that carried it, and only then the
      # late result's own turn.
      assert tool_index < ack_index
      assert ack_index < drained_index
      assert drained_index < done_index
      assert done_index < late_index
      assert late_index < final_index

      # The late notice carries the batch's *real* results, and the real
      # results report the disposition the deliveries resolved (issue #36
      # decision 5): the backgrounded message was `:delivered`, the one that
      # arrived after the batch left `:executing_tools` was queued behind it.
      late = text_of(Enum.at(messages, late_index))

      assert late =~ "[Message from agent \"#{name}\"]\nsecond"
      assert late =~ "Message delivered to #{name}"
      assert late =~ "Message queued for #{name} (busy)"

      # The combined late batch is the second delivery, and it came after the
      # first: the two deliveries kept their order.
      assert {first_at, _} = :binary.match(late, "Message delivered to")
      assert {second_at, _} = :binary.match(late, "Message queued for")
      assert first_at < second_at

      assert Enum.any?(user_texts(third), &(&1 =~ "Message from agent"))

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "human messages during a turn" do
    test "1.1.10 a human message inside a tool batch backgrounds it and lands alone, in its own mode" do
      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: multi_mode_vocation_id_for_test()
        })

      park_llm_requests(pid)
      park_agent_sends(pid)

      MockClient.set_tool_response(%{
        text: "Calling a tool",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "peer note"}
          }
        ]
      })

      MockClient.set_response("Done")
      MockClient.set_response("After the note")

      :ok = Agent.chat(pid, "start the turn")

      {first, llm1} = next_request()
      assert Enum.any?(user_texts(first), &(&1 =~ "start the turn"))
      release_llm(llm1)

      # The batch reached the tool worker, which is parked before its
      # `agents-send`: the agent really is `:executing_tools`.
      assert_receive {:send_blocked, worker}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :executing_tools

      # A human message with a mode now backgrounds the batch and is delivered
      # mid-batch — never dropped — and its mode is applied at delivery, not
      # while it was queued.
      :ok = Agent.chat(pid, "human note", "plan", "alice")
      assert_receive {:chat_inbox, %{count: 1}}, 500

      {second, llm2} = next_request()

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :streaming
      assert state.live.inbox == []
      assert state.live.mode == "plan"

      # The batch is still running (its worker is parked), and the human
      # message is already in the transcript behind the machine's synthetic
      # result and ack.
      assert Enum.map(state.chat_state.messages, &elem(&1, 0)) ==
               [:system, :user, :assistant, :tool, :assistant, :user]

      assert text_of(Enum.at(state.chat_state.messages, 5)) == "[mode: plan]\nhuman note"

      # It rides in on the next request, bare: no sender framing, so a queued
      # human message reads exactly like one typed while the agent was idle.
      assert Enum.any?(user_texts(second), &(&1 == "[mode: plan]\nhuman note"))
      refute Enum.any?(user_texts(second), &(&1 =~ "peer note"))

      # Releasing the batch runs its `agents-send` while this agent is
      # streaming, so the peer's entry queues behind the delivered message.
      send(worker, :release_send)

      # The batch returns with no live worker to settle it, so its real result
      # arrives as a queued notice behind the peer's entry.
      assert_receive {:chat_inbox, %{count: 2}}, 500

      # The delivered message's turn ends, and the boundary drain delivers the
      # two queued entries as one batch.
      release_llm(llm2)
      {third, llm3} = next_request()
      release_llm(llm3)

      # streaming -> executing_tools -> executing_tools (the mode the delivery
      # applies, published while the batch is still executing: `currentMode`
      # rides the status payload without changing the status) -> streaming (the
      # backgrounding) -> idle. No `idle` before that third `streaming`: the
      # delivery did not wait for a turn end.
      assert statuses_until_idle() == [
               "streaming",
               "executing_tools",
               "executing_tools",
               "streaming",
               "idle"
             ]

      assert statuses_until_idle() == ["streaming", "idle"]

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.inbox == []
      # The human's mode is now the agent's mode.
      assert state.live.mode == "plan"

      messages = state.chat_state.messages

      tool_index = Enum.find_index(messages, &match?({:tool, _}, &1))
      ack_index = Enum.find_index(messages, &(text_of(&1) =~ "running in the background"))
      human_index = Enum.find_index(messages, &(text_of(&1) =~ "human note"))
      done_index = Enum.find_index(messages, &(text_of(&1) == "Done"))
      peer_index = Enum.find_index(messages, &(text_of(&1) =~ "peer note"))
      final_index = Enum.find_index(messages, &(text_of(&1) =~ "After the note"))

      assert is_integer(tool_index), "expected the synthetic tool result"
      assert is_integer(ack_index), "expected the backgrounding ack"
      assert is_integer(human_index), "expected the delivered human message"
      assert is_integer(done_index), "expected the response to the human's turn"
      assert is_integer(peer_index), "expected the delivered peer message"
      assert is_integer(final_index), "expected the final assistant response"

      # The synthetic result, its ack, the human message, the response to the
      # turn it started, and only then the peer's entry: the delivery did not
      # merge the two, and it did not end the turn to start a fresh one.
      assert tool_index < ack_index
      assert ack_index < human_index
      assert human_index < done_index
      assert done_index < peer_index
      assert peer_index < final_index
      assert text_of(Enum.at(messages, human_index)) == "[mode: plan]\nhuman note"

      # The peer's entry arrives with the batch's late result, in one batch: the
      # entry keeps the agent label that disambiguates it, and the late result
      # reports the disposition the delivery resolved.
      late = text_of(Enum.at(messages, peer_index))
      assert late =~ "[Message from agent \"#{name}\"]\npeer note"
      assert late =~ "Message queued for #{name} (busy)"
      assert Enum.any?(user_texts(third), &(&1 =~ "peer note"))

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "a result that arrives after the delivered turn has ended" do
    test "the notice is delivered and the agent goes idle again" do
      # The shape the parked harness above deliberately avoids: the batch's
      # result arrives when the turn that backgrounded it is already over. That
      # is very reachable in production — a 60 s `shell-cmd` backgrounded by a
      # quick message whose turn ends in seconds — and nothing else wakes an
      # idle agent, so the notice would sit in the queue forever and an
      # `agents-wait` would resolve with the pre-result answer.
      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      park_agent_sends(pid, hold_result: true)

      MockClient.set_tool_response(%{
        text: "Queueing",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "note"}
          }
        ]
      })

      MockClient.set_response("After the note")
      MockClient.set_response("After the notice")

      :ok = Agent.chat(pid, "start the turn")

      # The batch reached the tool worker, parked before its `agents-send`.
      assert_receive {:send_blocked, tool}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :executing_tools

      # Release it: the message reaches this same agent, so the batch
      # backgrounds itself and the message is delivered now.
      send(tool, :release_send)

      # The worker parks again *after* the delivery, so the batch is still
      # running while the delivered turn runs to its end.
      assert_receive {:send_delivered, ^tool}, 500

      # The delivered turn ends: the agent is idle, the batch is still in the
      # background, and nothing is queued behind it.
      assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]

      idle = :sys.get_state(pid)

      assert Machine.status_for(idle.live.machine) == :idle
      assert map_size(idle.live.machine.work.backgrounded) == 1
      assert idle.live.inbox == []
      assert Enum.any?(user_texts(idle.chat_state.messages), &(&1 =~ "note"))

      # Now the batch returns. The agent is idle and nothing else is in flight,
      # so the result must start the notice's own turn.
      send(tool, :release_result)

      assert statuses_until_idle() == ["streaming", "idle"]

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.backgrounded == %{}
      assert state.live.inbox == []

      # The notice carries the batch's real result, which reports the
      # disposition the delivery resolved (decision D5): the message that
      # backgrounded the batch was `:delivered`.
      assert Enum.any?(
               user_texts(state.chat_state.messages),
               &(&1 =~ "backgrounded command" and &1 =~ "Message delivered to #{name}")
             )

      # The notice answers the call the synthetic result promised, and it says
      # so durably: the fulfilled ids ride the delivered message's metadata
      # (`Inbox.build_drained_message/3`), so a later load tells this kept
      # promise from one the process died with.
      notice =
        Enum.find(
          state.chat_state.messages,
          &(&1 |> text_of() |> String.contains?("backgrounded command"))
        )

      assert {_role, %{metadata: %{"backgrounded_fulfilled_ids" => ["send_1"]}}} = notice

      # The load path agrees, in memory and as persisted: nothing is lost, so no
      # lost-promise record is appended. Without the marker the restored
      # transcript would still carry the synthetic `state: "backgrounded"` part
      # and the heal would claim the call was "lost when this agent restarted"
      # — a lie about a result that arrived.
      assert Repair.classify_load(state.chat_state.messages) == :ok

      {:ok, attrs} = Persistence.build_attrs_for_start(current_space_id(), name)
      assert attrs.load_heal == nil

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "the runtime's own result (decision D1)" do
    test "a batch aggregate preempts the batch, like a peer's message" do
      # D1 is "any incoming message backgrounds the batch", and the runtime's
      # own result is an incoming message: a coordinator's aggregate must be
      # delivered now, not queued behind a batch that may run for another hour.
      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      park_agent_sends(pid, hold_result: true)

      MockClient.set_tool_response(%{
        text: "Sending",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "note"}
          }
        ]
      })

      MockClient.set_response("After the aggregate")
      MockClient.set_response("After the batch")

      :ok = Agent.chat(pid, "start the turn")

      assert_receive {:send_blocked, tool}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :executing_tools

      # The aggregate is the disposition the coordinator relies on: `:delivered`
      # means it reached the transcript.
      assert {:ok, :delivered} =
               Agent.deliver_internal(pid, "agents-batch", "the aggregate", :notice)

      mid = :sys.get_state(pid)

      # The notice is in the transcript and the batch has moved to the
      # background, still running: the delivery did not wait for it.
      assert Machine.status_for(mid.live.machine) == :streaming
      assert map_size(mid.live.machine.work.backgrounded) == 1
      assert mid.live.inbox == []
      assert Enum.any?(user_texts(mid.chat_state.messages), &(&1 =~ "the aggregate"))

      # Release the batch: its own send runs, it returns, and everything it
      # queued drains. The turn must reach idle for the teardown.
      send(tool, :release_send)
      assert_receive {:send_delivered, ^tool}, 500
      send(tool, :release_result)

      assert Eventually.eventually(
               fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
               timeout: 500
             )

      state = :sys.get_state(pid)

      assert state.live.inbox == []
      assert state.live.machine.work.backgrounded == %{}
    end
  end

  describe "a stop during a backgrounded call" do
    test "kills the worker, records the cancellation and starts no new turn" do
      # A backgrounded call's promise is that its result arrives later as a
      # message. A stop voids that promise, so it must kill the worker (or the
      # batch runs on past the stop with its entry leaking) *and* say so in the
      # transcript. The record is an append, never an inbox entry: the stop's own
      # `:stop_timer` transition drains the inbox, so an enqueued notice would
      # start exactly the turn the human stopped.
      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      park_llm_requests(pid)
      park_agent_sends(pid)

      MockClient.set_tool_response(%{
        text: "Sending",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "note"}
          }
        ]
      })

      MockClient.set_response("After the note")

      :ok = Agent.chat(pid, "start the turn")

      {_first, llm1} = next_request()
      release_llm(llm1)

      # The batch reached the tool worker, which is parked before its
      # `agents-send`: the agent really is `:executing_tools` with a live worker
      # and an unanswered `tool_use`.
      assert_receive {:send_blocked, tool}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :executing_tools

      # A human message backgrounds the batch, so it is *still running* — parked
      # inside its call — when the stop lands.
      :ok = Agent.chat(pid, "human note")

      # The delivered message's turn is in flight (its request is parked), so
      # nothing else will move the machine before the stop.
      {_second, _llm2} = next_request()

      backgrounded = :sys.get_state(pid).live.machine.work.backgrounded
      assert [ref] = Map.keys(backgrounded)
      assert backgrounded[ref] == %{pid: tool, calls: 1}

      monitor = Process.monitor(tool)

      assert :ok = Agent.stop_chat(pid, self())

      # The worker's death is the stop's doing, not the parked harness's safety
      # valve: the `:DOWN` arrives while the worker is still parked.
      assert_receive {:DOWN, ^monitor, :process, ^tool, :killed}, 500

      # streaming -> executing_tools (the batch) -> streaming (the backgrounding)
      # -> idle (the stop). The stop is the turn's end, so no `idle` precedes it.
      assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]

      # No new turn starts: the status sequence has no frame past the stop, and
      # nothing asks the model for anything. Both are `refute_received/1` rather
      # than waits because the sync below drains the stop's whole synchronous
      # follow-up chain first: a turn that started in it — the drain the stop's
      # own `:stop_timer` runs — would have broadcast its `streaming` frame (and
      # been dispatched from its deferred `:iterate`) by now.
      _ = :sys.get_state(pid)
      refute_received {:chat_status, _}
      refute_received {:llm_request, _, _}

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.backgrounded == %{}
      assert state.live.inbox == []

      # The record is one message: the tail was the delivered human message (a
      # wire-user role), so the notice and its acknowledgement land together
      # instead of forcing the appender's terminal bridge to fabricate an
      # acknowledgement of its own.
      assert Enum.map(state.chat_state.messages, &elem(&1, 0)) ==
               [:system, :user, :assistant, :tool, :assistant, :user, :assistant]

      cancelled = text_of(List.last(state.chat_state.messages))

      assert cancelled =~ "cancelled when the conversation was stopped"
      assert cancelled =~ "its result will not arrive"
      assert cancelled =~ "I will not wait for it"

      # The batch's worker is dead, so its result cannot arrive — but a late one
      # must not deliver a second notice for a call the record already reported.
      # Both orders are no-ops: while `:stopping` the stop guards drop it, and
      # once the entry is cleared the idle clause drops it as stale.
      send(pid, {:tool_results, ref, [late_result()]})
      _ = :sys.get_state(pid)

      assert :sys.get_state(pid).chat_state.messages == state.chat_state.messages

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  defp late_result do
    %ToolResult{
      tool_call_id: "send_1",
      name: "shell-cmd",
      arguments: %{},
      content: "late output",
      is_error: false
    }
  end
end
