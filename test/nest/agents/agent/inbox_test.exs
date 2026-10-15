defmodule Nest.Agents.Agent.InboxTest do
  @moduledoc """
  Tests for the agent inbox: immediate delivery to an idle agent, queueing
  while busy (an `agents-send` from another agent and a human chat message),
  the combined drain with its one-mode rule, the reply obligation, and the
  error paths. The LLM-facing rendering of a drain batch — the labels, the
  bare notices and the over-cap scratch-file pointer — is
  `Nest.Agents.Agent.InboxRenderTest`'s.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Nest.Agents.AgentStateHelpers, only: [set_status: 2, wait_idle: 1, replace_state: 2]
  import Nest.Agents.AgentTurnTestHelpers, only: [text_of: 1, user_texts: 1]

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup do
    # Modes `plan` and `review` on top of the `chat` default, so the
    # drain-mode tests can request a mode the agent is not already in.
    # `chat` stays the default because `Vocations.default_mode/1` is the
    # lexicographically first mode.
    {pid, name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.multi_mode_vocation_id_for_test()
      })

    %{pid: pid, name: name}
  end

  test "delivery to an idle agent starts a turn with the message as a user message", %{pid: pid} do
    assert {:ok, :delivered} = Agent.deliver_message(pid, "peer", "do the thing")
    # allowlist: snapshot — inbox + messages
    state = :sys.get_state(pid, 1_000)

    assert Enum.any?(
             user_texts(state.chat_state.messages),
             &(&1 =~ "[Message from agent \"peer\"]" and &1 =~ "do the thing")
           )

    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # The delivery consumed the entry, so the only queue frame due is the
    # consume's own removal — never an append frame (see the parked-drain
    # test below for the other half of this contract). The frame names the id
    # that went, not the (empty) queue that is left.
    assert state.live.inbox == []
    assert_receive {:chat_inbox, %{op: "remove", count: 0, ids: [_]}}, 1_000
    refute_received {:chat_inbox, _}
  end

  test "delivery to a busy agent queues and drains all queued messages together on idle", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "alice", "first message")
    assert_receive {:chat_inbox, %{count: 1}}, 1_000

    assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "second message")
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
    # allowlist: snapshot — inbox + messages
    state = :sys.get_state(pid, 1_000)

    assert state.live.inbox == []

    combined =
      Enum.find(
        user_texts(state.chat_state.messages),
        &(&1 =~ "first message" and &1 =~ "second message")
      )

    assert combined =~ "[Message from agent \"alice\"]"
    assert combined =~ "[Message from agent \"bob\"]"

    wait_idle(pid)
  end

  test "deliver_internal delivers the runtime's own result to an idle agent", %{pid: pid} do
    # The runtime's own result (a batch aggregate): bare — no agent said it, so
    # no `[Message from agent …]` label — and drained through the turn executor
    # when the target is idle, exactly like a peer delivery.
    assert {:ok, :delivered} = Agent.deliver_internal(pid, "agents-batch", ~s(["done"]), :notice)
    # allowlist: snapshot — inbox + messages
    state = :sys.get_state(pid, 1_000)
    assert [text] = Enum.filter(user_texts(state.chat_state.messages), &(&1 =~ ~s(["done"])))
    refute text =~ "Message from agent"

    # The delivery is a synchronous `GenServer.call`, but the turn it starts is
    # not: this waits for that turn to end on the `chat:status` frame that
    # decides it — the idle that carries an empty queue (`wait_idle/1`).
    wait_idle(pid)
    assert state.live.inbox == []
  end

  test "deliver_internal is never refused, even at the peer cap", %{pid: pid} do
    set_status(pid, :streaming)

    # Fill the queue to the peer cap: the next peer delivery is refused...
    Enum.each(1..100, fn n ->
      assert {:ok, :queued} = Agent.deliver_message(pid, "peer-#{n}", "queued #{n}")
    end)

    assert {:error, :inbox_full} = Agent.deliver_message(pid, "peer", "one too many")

    # ...while the runtime's own result queues anyway. Refusing it would lose
    # the batch's whole output (the coordinator has nowhere else to put it).
    assert {:ok, :queued} = Agent.deliver_internal(pid, "agents-batch", ~s(["done"]), :notice)

    assert List.last(Agent.get_public_info(pid, 1_000).pending_messages)["content"] ==
             ~s(["done"])

    reset_to_idle(pid)
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
             catch_exit(Agent.deliver_internal(gone, "agents-batch", "x", :notice))
  end

  test "delivery to a broken agent returns an error and queues nothing", %{pid: pid} do
    # intentional: the disposition is the target's status, not the entry's
    # kind — every kind is refused alike, and nothing is queued.
    set_status(pid, :needs_repair)

    for kind <- [:agent, :query, :notice] do
      assert {:error, {:status, :needs_repair}} =
               Agent.deliver_message(pid, "peer", "hello", kind)

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
        assert {:ok, :queued} = Agent.deliver_message(pid, "peer", "does not fit")
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
    # `entry/5` builds the whole documented entry shape (`id`, `human?`,
    # `fulfilled_ids`, `retrieved`), which matters now that the count below is
    # read through `get_public_info/2` — that serializes the queue, and a
    # hand-rolled partial entry would crash it.
    full = for n <- 1..100, do: entry(:agent, "peer", "msg #{n}")

    :sys.replace_state(pid, fn state -> %{state | live: %{state.live | inbox: full}} end, 1_000)

    for kind <- [:agent, :query, :notice] do
      assert {:error, :inbox_full} = Agent.deliver_message(pid, "peer", "one too many", kind)
    end

    assert Agent.get_public_info(pid, 1_000).pending_message_count == 100
  end

  test "self-delivery is allowed", %{pid: pid, name: name} do
    assert {:ok, :delivered} = Agent.deliver_message(pid, name, "note to self")

    assert Enum.any?(user_texts(Agent.get_messages(pid, 1_000)), &(&1 =~ "note to self"))
    wait_idle(pid)
  end

  test "send_message/4 surfaces a missing target" do
    space_id = AgentTestHelpers.current_space_id()

    assert {:error, :not_found} =
             Agents.send_message(space_id, "alice", "does-not-exist", "hello")
  end

  describe "query entries and the reply obligation" do
    test "a query to an idle agent is delivered as the peer's words and owes a reply", %{pid: pid} do
      # intentional: a query is delivered exactly like a peer message (decision
      # 7 — the requester is an agent, so the target reads `[Message from agent
      # "X"]`), and the delivery is what incurs the obligation, on the machine.
      # The whole turn — mock LLM, the gate's reminder, a second mock LLM and
      # the give-up — runs as soon as the delivery starts, and it can finish
      # before a `capture_log` installed afterwards. So the delivery and the
      # assertions about what it did go *inside* the capture: the give-up cannot
      # precede the window that is supposed to catch its warning. (Measured: a
      # 50 ms gap between the debt assertion and the capture reproduced the
      # failure exactly — `left: ""` with the warning landing in a concurrent
      # test's capture.)
      log =
        capture_log(fn ->
          assert {:ok, :delivered} = Agent.deliver_message(pid, "peer", "summarize this", :query)
          # allowlist: snapshot — messages + owed_replies
          state = :sys.get_state(pid, 1_000)

          assert Enum.any?(
                   user_texts(state.chat_state.messages),
                   &(&1 =~ "[Message from agent \"peer\"]" and &1 =~ "summarize this")
                 )

          assert Machine.owed_senders(state.live.machine) == ["peer"]

          # The debt rides the status broadcast (decision 15): the turn started,
          # so the idle -> streaming frame is the client's first sight of it.
          #
          # The turn then ends with the debt unpaid, so the gate gives up on it
          # and tries to tell the requester. "peer" is a name, not a running
          # agent, so that notice is *refused*: expected here, captured and
          # asserted rather than left to print. The notification is asserted
          # inside the capture because it is broadcast after the warning, which
          # is what proves the warning landed before the block ended.
          assert_receive {:chat_status, %{status: "streaming", owedReplies: ["peer"]}}, 1_000
          wait_idle(pid)
          assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 1_000
        end)

      assert log =~ "reply give-up (no_reminder) could not reach peer: :not_found"
    end

    test "a busy agent queues every delivery kind, kind-tagged, owing nothing yet", %{pid: pid} do
      # intentional: the disposition is the same for every kind — the kind is
      # provenance, not a routing decision — and the wire tag is what the panel
      # renders. Only a delivered query owes a reply, so a query queued behind a
      # busy agent that never drains creates no debt.
      set_status(pid, :streaming)
      kinds = [:agent, :query, :notice]

      for {kind, n} <- Enum.with_index(kinds, 1) do
        assert {:ok, :queued} = Agent.deliver_message(pid, "peer", "msg #{n}", kind)

        # The frame is the delta for this delivery alone (issue #27): the entry
        # it appended, tagged with its kind, and the queue length it left
        # behind — never the accumulated list, which the fetch below reads.
        assert_receive {:chat_inbox, %{op: "append", count: ^n, messages: [entry]}}, 1_000

        assert entry["kind"] == Atom.to_string(kind)
        assert entry["content"] == "msg #{n}"
      end

      info = Agent.get_public_info(pid, 1_000)

      assert Enum.map(info.pending_messages, & &1["kind"]) ==
               Enum.map(kinds, &Atom.to_string/1)

      assert Enum.map(info.pending_messages, & &1["from"]) == ["peer", "peer", "peer"]
      assert Enum.map(info.pending_messages, & &1["mode"]) == [nil, nil, nil]
      assert info.owed_replies == []

      # The fabricated busy status is test-only: leave the agent idle and the
      # queue empty so the teardown's zero-in-flight assertion holds.
      reset_to_idle(pid)
    end

    test "a stop reports both the debt and the query that never set one", %{pid: pid} do
      # intentional: a query owes nothing until it is *delivered* (issue #31
      # §1.3), so a process that dies with one still queued fires no give-up and
      # tells the requester nothing at all — the requester waits on an answer
      # that cannot come, and this warning is the only trace of it. A debt, by
      # contrast, was delivered: the two losses are reported on their own lines
      # because they are not the same loss.
      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "queued question", :query)
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
      # The cast is the explicit `Agent.chat/5` with `human?: true` (the arity
      # the chat channel uses), so this is the busy half of the recall-list
      # wiring: `Callbacks.chat_or_queue/5` -> `Inbox.deliver_user_message/5`
      # lands the flag on the entry, and `build_drained_message/3` turns it into
      # the `origin: "human"` marker. Both halves are asserted below; the idle
      # half is `agent_chat_mode_test.exs`'s "tags a human chat but not a
      # spawn-style kickoff".
      for {status, n} <- Enum.with_index([:streaming, :executing_tools, :compacting], 1) do
        set_status(pid, status)

        assert :ok = Agent.chat(pid, "queued while #{status}", "plan", "alice", true)

        assert_receive {:chat_inbox, %{count: ^n}}, 1_000

        info = Agent.get_public_info(pid, 1_000)

        assert info.status == status
        assert info.pending_message_count == n
      end

      # allowlist: snapshot — inbox + messages
      state = :sys.get_state(pid, 1_000)
      inbox = state.live.inbox

      assert Enum.map(inbox, & &1.kind) == [:user, :user, :user]
      assert Enum.map(inbox, & &1.from) == ["alice", "alice", "alice"]
      assert Enum.map(inbox, & &1.mode) == ["plan", "plan", "plan"]
      assert Enum.map(inbox, & &1.human?) == [true, true, true]

      assert Enum.map(inbox, & &1.content) == [
               "queued while streaming",
               "queued while executing_tools",
               "queued while compacting"
             ]

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
               %{"mode" => "plan", "origin" => "human"},
               %{"mode" => "plan", "origin" => "human"},
               %{"mode" => "plan", "origin" => "human"}
             ]
    end

    test "a message to an idle agent starts the turn immediately in the requested mode", %{
      pid: pid
    } do
      MockClient.set_response("ok")

      assert :ok = Agent.chat(pid, "hello now", "plan", "alice")

      assert_receive {:chat_status, %{status: "streaming"}}, 1_000
      # allowlist: snapshot — inbox + mode + messages
      state = :sys.get_state(pid, 1_000)

      assert state.live.inbox == []
      assert state.live.mode == "plan"
      assert Enum.any?(user_texts(state.chat_state.messages), &(&1 =~ "hello now"))
      assert Enum.any?(user_texts(state.chat_state.messages), &(&1 =~ "[mode: plan]"))

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
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

    test "a drain delivers each batch in its own mode, applying it at delivery time", %{pid: pid} do
      # intentional: the mode is applied when the batch is delivered, never when
      # an entry is queued (`state.live.mode` feeds the ongoing turn's
      # `ctx.caps`). A human message is delivered alone, so each human message
      # runs in the mode it asked for — the old "two queued human messages, the
      # older one runs under the newer one's caps" wart is gone — and the
      # winner is resolved afresh at each delivery attempt.
      cases = [
        {[entry(:agent, "peer", "peer note")], ["chat"], "an agent batch keeps the agent's mode"},
        {[entry(:user, "alice", "plan please", "plan")], ["plan"],
         "a human message runs in its own mode"},
        {[
           entry(:user, "alice", "plan please", "plan"),
           entry(:user, "bob", "review please", "review")
         ], ["plan", "review"], "two human messages are two batches, each in its own mode"},
        {[entry(:agent, "peer", "no mode"), entry(:user, "alice", "plan please", "plan")],
         ["chat", "plan"], "a human message never merges into the agent run ahead of it"},
        {[entry(:user, "alice", "bogus please", "bogus")], ["chat"],
         "an unknown mode falls back to the vocation default, like an idle chat"}
      ]

      for {entries, expected_modes, label} <- cases do
        before = Agent.get_public_info(pid, 1_000).message_count
        stage_drain(pid, entries)

        Agent.stop_chat(pid, self())

        # The drain's last consume frame is the fence: the empty queue the
        # delivered modes below are read from.
        assert_receive {:chat_inbox, %{count: 0}}, 1_000

        wait_idle(pid)

        delivered =
          Agent.get_messages(pid, 1_000)
          |> Enum.drop(before)
          |> Enum.filter(&match?({:user, _}, &1))
          |> Enum.map(&mode_of/1)

        assert delivered == expected_modes, label
      end
    end

    test "a human message drained behind a busy turn is tagged as the human's own words", %{
      pid: pid
    } do
      # A human message that arrives mid-turn is queued and later delivered
      # through the same `build_drained_message/3` a peer batch uses, so the
      # `origin: "human"` marker has to come from the entry's `human?` flag.
      # Without it the prompt would drop out of the Ctrl/Cmd+Up recall list.
      #
      # The entry is injected with `:sys.replace_state`, so this pins
      # `origin_metadata/1` and the drain on a hand-built entry — not
      # `deliver_user_message/5`'s own wiring of the flag. That wiring is
      # covered by this file's "a message to a busy agent is queued with its
      # sender and mode" (the busy path: `Agent.chat/5` -> the entry -> the
      # drain) and by the `build_drained_message/3` cases below;
      # `agent_chat_mode_test.exs`'s "tags a human chat but not a spawn-style
      # kickoff" covers only the idle path.
      before = Agent.get_public_info(pid, 1_000).message_count
      stage_drain(pid, [entry(:user, "alice", "queued prompt", "plan", true)])

      Agent.stop_chat(pid, self())

      assert_receive {:chat_inbox, %{count: 0}}, 1_000

      wait_idle(pid)

      appended_user_metadata =
        Agent.get_messages(pid, 1_000)
        |> Enum.drop(before)
        |> Enum.flat_map(fn
          {:user, %{metadata: metadata}} -> [metadata]
          _ -> []
        end)

      assert [%{"origin" => "human"}] = appended_user_metadata
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

  # A live turn (so `stop_chat` reaches the idle transition that drains)
  # carrying `entries`, with the mode reset to the vocation default so each
  # drain-mode case starts from a known baseline.
  defp stage_drain(pid, entries) do
    replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | mode: "chat",
              inbox: entries,
              machine: Machine.status_to_machine(state.live.machine, :streaming)
          }
      }
    end)
  end

  defp entry(kind, from, content, mode \\ nil, human? \\ false) do
    %{
      id: Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      human?: human?,
      fulfilled_ids: [],
      retrieved: false
    }
  end

  # The `[mode: X]` prefix `Dispatch.build_user_message/2` puts on a delivered
  # message, or nil when the message has none. Any mode name (dashes, uppercase)
  # is accepted, so the helper cannot silently report nil for a real mode.
  defp mode_of(message) do
    case Regex.run(~r/^\[mode: ([^\]]+)\]/, text_of(message)) do
      [_, mode] -> mode
      nil -> nil
    end
  end
end
