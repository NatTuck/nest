defmodule Nest.Agents.Agent.InboxTest do
  @moduledoc """
  Tests for the agent inbox: immediate delivery to an idle agent, queueing
  while busy (an `agents-send` from another agent and a human chat message),
  the combined drain, the reply obligations a stop loses, and the error paths.

  The LLM-facing rendering of a drain batch — the labels, the bare notices and
  the over-cap scratch-file pointer — is `Nest.Agents.Agent.InboxRenderTest`'s,
  the mode a drained batch applies is
  `Nest.Agents.Agent.Turn.ExecutorTest`'s, and the delta frames themselves are
  `Nest.Agents.Agent.InboxDeltaTest`'s.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Nest.Agents.AgentStateHelpers, only: [set_status: 2, wait_idle: 1, replace_state: 2]
  import Nest.Agents.AgentTurnTestHelpers, only: [user_texts: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.AgentTestHelpers

  setup do
    # An agent on a vocation that defines `plan` on top of the default, so the
    # human message below can ask for a mode the agent is not already in.
    {pid, name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.multi_mode_vocation_id_for_test()
      })

    %{pid: pid, name: name}
  end

  test "delivery to an idle agent starts a turn with the message as a user message", %{pid: pid} do
    assert {:ok, :delivered} = Agent.deliver_note(pid, "peer", "do the thing")
    # allowlist: snapshot — messages
    state = :sys.get_state(pid, 1_000)

    assert Enum.any?(
             user_texts(state.chat_state.messages),
             &(&1 =~ "[From agent peer | mode: act]" and &1 =~ "do the thing")
           )

    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # The delivery consumed the entry, so the only queue frame due is the
    # consume's own removal — never an append frame (see the parked-drain
    # test below for the other half of this contract). The frame names the id
    # that went, and its `count: 0` is the queue it left.
    #
    # 1000 ms is the suite's fence for `test/` (`test/test_helper.exs:157`):
    # this frame is broadcast by the agent process, not by this one.
    assert_receive {:chat_inbox, %{op: "remove", count: 0, ids: [_]}}, 1_000
    refute_received {:chat_inbox, _}
  end

  test "delivery to a busy agent queues and drains all queued messages together on idle", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_note(pid, "alice", "first message")
    assert_receive {:chat_inbox, %{count: 1}}, 1_000

    assert {:ok, :queued} = Agent.deliver_note(pid, "bob", "second message")
    assert_receive {:chat_inbox, %{count: 2}}, 1_000

    assert Enum.map(Agent.get_public_info(pid, 1_000).pending_messages, & &1["from"]) == [
             "alice",
             "bob"
           ]

    # The in-flight turn ends (preempted here); the resulting idle
    # transition clears `cancelled` and drains the queued messages.
    Agent.stop_chat(pid, self())

    # `stop_chat/2` is a call, but the drain it triggers is not: the bounded
    # stop timer owns the terminal transition, so the drain's own consume frame
    # is the fence, and it is the last one due — the queue is empty after it.
    assert_receive {:chat_inbox, %{count: 0}}, 1_000
    # allowlist: snapshot — messages
    state = :sys.get_state(pid, 1_000)

    combined =
      Enum.find(
        user_texts(state.chat_state.messages),
        &(&1 =~ "first message" and &1 =~ "second message")
      )

    assert combined =~ "[From agent alice | mode: act]"
    assert combined =~ "[From agent bob | mode: act]"

    wait_idle(pid)
  end

  test "deliver_internal to a parent that is gone exits with :noproc" do
    # The contract the batch coordinator's delivery relies on: a missing parent
    # is an exit the caller must handle, and `:noproc` is the only shape that
    # means "certainly not delivered" (a timeout leaves the request queued).
    #
    # The death is forced and *observed* before the call, so the pid is
    # certainly gone: a process spawned to exit immediately can be dead before
    # the monitor is attached, and its DOWN reason is then `:noproc`, not
    # `:killed`.
    gone =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(gone)
    Process.exit(gone, :kill)
    assert_receive {:DOWN, ^ref, :process, ^gone, :killed}, 1_000

    assert {:noproc, _reason} =
             catch_exit(Agent.deliver_internal(gone, "agents-batch", "x", :runtime))
  end

  test "delivery to a broken agent returns an error and queues nothing", %{pid: pid} do
    # intentional: the disposition is the target's status, not the entry's
    # kind — every kind is refused alike, and nothing is queued.
    set_status(pid, :needs_repair)

    for kind <- [:agent, :query, :runtime] do
      assert {:error, {:status, :needs_repair}} =
               Agent.deliver_note(pid, "peer", "hello", kind)

      assert Agent.get_public_info(pid, 1_000).pending_messages == []
    end
  end

  test "a delivery whose drain parks still broadcasts the queued entry", %{pid: pid} do
    # intentional: the idle path enqueues and drains in one step, and a drain
    # that parks the message (here a `:cannot_compact` block, forced by a
    # context limit nothing can fit) leaves it queued. Without a frame for it
    # the entry's content would be reachable only by a client refetch — the
    # #26 visibility hole. So: whenever the entry is still queued after the
    # drain, a `chat:inbox` frame must have gone out for it.
    replace_state(pid, fn state ->
      %{state | llm_metrics: %{state.llm_metrics | context_limit: 1}}
    end)

    # The overflow broadcast is the visible half of the block; capture it so the
    # suite's console stays clean and assert it actually happened.
    log =
      capture_log(fn ->
        assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "does not fit")
      end)

    assert log =~ "cannot fit the system prompt"

    info = Agent.get_public_info(pid, 1_000)

    assert [%{"content" => "does not fit", "kind" => "agent"}] = info.pending_messages
    assert_receive {:chat_inbox, %{count: 1}}, 1_000
    # Nothing was consumed, so the enqueue frame above is the only one: a
    # consume's empty frame would mean the entry had been delivered.
    refute_received {:chat_inbox, %{count: 0}}
    assert info.status == :context_overflow
  end

  test "delivery is rejected when the inbox is full", %{pid: pid} do
    # `entry/5` builds the whole documented entry shape (`id`, `source`,
    # `fulfilled_ids`), which matters now that the count below is read through
    # `get_public_info/2` — that serializes the queue, and a hand-rolled partial
    # entry would crash it.
    full = for n <- 1..100, do: entry(:agent, "peer", "msg #{n}")

    :sys.replace_state(pid, fn state -> %{state | live: %{state.live | inbox: full}} end, 1_000)

    for kind <- [:agent, :query, :runtime] do
      assert {:error, :inbox_full} = Agent.deliver_note(pid, "peer", "one too many", kind)
    end

    assert Agent.get_public_info(pid, 1_000).pending_message_count == 100
  end

  test "self-delivery is allowed", %{pid: pid, name: name} do
    assert {:ok, :delivered} = Agent.deliver_note(pid, name, "note to self")

    assert Enum.any?(user_texts(Agent.get_messages(pid, 1_000)), &(&1 =~ "note to self"))
    wait_idle(pid)
  end

  describe "the reply obligations a stop loses" do
    test "a stop reports both the debt and the query that never set one", %{pid: pid} do
      # intentional: a query owes nothing until it is *delivered* (issue #31
      # §1.3), so a process that dies with one still queued fires no give-up and
      # tells the requester nothing at all — the requester waits on an answer
      # that cannot come, and this warning is the only trace of it. A debt, by
      # contrast, was delivered: the two losses are reported on their own lines
      # because they are not the same loss.
      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_note(pid, "bob", "queued question", :query)
      # allowlist: harness — Inbox.log_lost_replies/1's argument
      state = :sys.get_state(pid, 1_000)
      assert Machine.owed_senders(state.live.machine) == []

      state = %{
        state
        | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
      }

      log = capture_log(fn -> assert :ok = Inbox.log_lost_replies(state) end)

      # Both are inclusions: `capture_log` also returns lines from concurrent
      # tests, so only the presence of each line can be asserted.
      assert log =~ "stopping with undelivered queued queries from [\"bob\"]"
      assert log =~ "the queue is in-process state and is lost"
      assert log =~ "stopping with unpaid replies to [\"peer\"]"
      assert log =~ "the obligation is in-process state and is lost"

      reset_to_idle(pid)
    end
  end

  describe "human chat messages" do
    test "a message to a busy agent is queued with its sender and mode", %{pid: pid} do
      # intentional: the disposition is the agent's own status read, so a
      # human message that arrives mid-turn is queued — never dropped or
      # rejected — with the content stored verbatim and the requested mode
      # recorded for the drain.
      #
      # The cast is the explicit `Agent.chat/5` with `:composed` (the arity
      # the chat channel uses), so this is the busy half of the recall-list
      # wiring: `Callbacks.chat_or_queue/5` -> `Inbox.deliver_user_message/5`
      # lands the flag on the entry, and `build_drained_message/3` turns it into
      # the `origin: "human"` marker. The marker is asserted below; the idle
      # half is `agent_chat_mode_test.exs`'s "tags a human chat but not a
      # spawn-style kickoff".
      for {status, n} <- Enum.with_index([:streaming, :executing_tools, :compacting], 1) do
        set_status(pid, status)

        assert :ok = Agent.chat(pid, "queued while #{status}", "plan", "alice", :composed)

        assert_receive {:chat_inbox, %{count: ^n}}, 1_000

        info = Agent.get_public_info(pid, 1_000)

        assert info.status == status
        assert info.pending_message_count == n
      end

      # The queue the client reads: one entry per push, each naming the sender
      # and the mode it asked for, with the content stored verbatim.
      queued = Agent.get_public_info(pid, 1_000).pending_messages

      assert Enum.map(queued, &{&1["content"], &1["from"], &1["kind"], &1["mode"]}) == [
               {"queued while streaming", "alice", "user", "plan"},
               {"queued while executing_tools", "alice", "user", "plan"},
               {"queued while compacting", "alice", "user", "plan"}
             ]

      # allowlist: snapshot — messages
      state = :sys.get_state(pid, 1_000)

      # Queueing is the only effect: no turn started, nothing appended.
      assert Enum.map(state.chat_state.messages, &elem(&1, 0)) == [:system]

      # Then drain them for real. The fabricated busy status is test-only, so
      # the stop's own drain is the transition under test: each queued human
      # message is delivered as its own batch, and every delivered message must
      # carry the marker — a prompt sent while the agent was busy reaches the
      # Ctrl/Cmd+Up recall list exactly like one sent while it was idle.
      before = length(state.chat_state.messages)

      Agent.stop_chat(pid, self())

      # One batch per human message, so the last consume frame — the empty
      # queue — is the fence that every queued message was delivered.
      assert_receive {:chat_inbox, %{count: 0}}, 1_000

      wait_idle(pid)

      drained_metadata =
        Agent.get_messages(pid, 1_000)
        |> Enum.drop(before)
        |> Enum.flat_map(fn
          {:user, %{metadata: metadata}} -> [metadata]
          _ -> []
        end)

      assert drained_metadata == [
               %{"mode" => "plan", "origin" => "human", "composed" => true},
               %{"mode" => "plan", "origin" => "human", "composed" => true},
               %{"mode" => "plan", "origin" => "human", "composed" => true}
             ]
    end

    test "a message to a broken agent is dropped and nothing is queued", %{pid: pid} do
      # intentional: every broken status needs an operator action first; the
      # channel has already told the human why, so the cast is a no-op (it
      # must not fall through to the pipeline).
      log =
        capture_log(fn ->
          for status <- Machine.blocked_phases() do
            set_status(pid, status)
            before = Agent.get_messages(pid, 1_000)

            assert :ok = Agent.chat(pid, "too late", "plan", "alice")
            # allowlist: barrier — a dropped cast broadcasts nothing
            _ = :sys.get_state(pid, 1_000)
            # allowlist: snapshot — inbox + messages + status
            state = :sys.get_state(pid, 1_000)

            assert state.live.inbox == [], "#{status} must queue nothing"
            assert state.chat_state.messages == before, "#{status} must not append"
            assert Machine.status_for(state.live.machine) == status
          end
        end)

      # The drop is logged, not silent: `Agents.chat/4` is public and has
      # non-channel callers whose message would otherwise vanish without trace.
      assert log =~ "dropping a chat message while status=:needs_repair"
      assert log =~ "dropping a chat message while status=:compaction_loop_detected"
    end
  end

  # Undo a fabricated busy status (and its queued entries) so a test that
  # only inspects the queue leaves the agent idle for the teardown.
  defp reset_to_idle(pid) do
    replace_state(pid, fn state ->
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

  defp entry(kind, from, content, mode \\ nil, source \\ false) do
    %{
      id: Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      source: source,
      fulfilled_ids: []
    }
  end
end
