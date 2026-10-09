defmodule Nest.Agents.Agent.InboxTest do
  @moduledoc """
  Tests for the agent inbox: the entry shape, immediate delivery to an idle
  agent, queueing while busy (an `agents-send` from another agent and a
  human chat message), the combined drain with its one-mode rule, the
  over-cap scratch-file offload, and the error paths.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  # A big-enough body to exceed the default 8000-token cap.
  @oversized String.duplicate("hello world ", 4_000)

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

    state = :sys.get_state(pid)

    assert Enum.any?(
             user_texts(state),
             &(&1 =~ "[Message from agent \"peer\"]" and &1 =~ "do the thing")
           )

    assert_receive {:chat_status, %{status: "idle"}}, 500

    # The delivery consumed the entry, so the only queue frame due is the
    # consume's own empty one — never an enqueue frame (see the parked-drain
    # test below for the other half of this contract).
    assert state.live.inbox == []
    assert_receive {:chat_inbox, %{count: 0, messages: []}}
    refute_receive {:chat_inbox, _}, 50
  end

  test "delivery to a busy agent queues and drains all queued messages together on idle", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "alice", "first message")
    assert_receive {:chat_inbox, %{count: 1}}, 500

    assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "second message")
    assert_receive {:chat_inbox, %{count: 2}}, 500

    state = :sys.get_state(pid)
    assert Enum.map(state.live.inbox, & &1.from) == ["alice", "bob"]

    # The in-flight turn ends (preempted here); the resulting idle
    # transition clears `cancelled` and drains the queued messages.
    Agent.stop_chat(pid, self())

    assert Eventually.eventually(
             fn -> :sys.get_state(pid).live.inbox == [] end,
             timeout: 500
           )

    state = :sys.get_state(pid)

    assert state.live.inbox == []
    assert_receive {:chat_inbox, %{count: 0}}, 500

    combined =
      Enum.find(user_texts(state), &(&1 =~ "first message" and &1 =~ "second message"))

    assert combined =~ "[Message from agent \"alice\"]"
    assert combined =~ "[Message from agent \"bob\"]"

    wait_idle(pid)
  end

  test "deliver_internal delivers the runtime's own result to an idle agent", %{pid: pid} do
    # The runtime's own result (a batch aggregate): bare — no agent said it, so
    # no `[Message from agent …]` label — and drained through the turn executor
    # when the target is idle, exactly like a peer delivery.
    assert {:ok, :delivered} = Agent.deliver_internal(pid, "agents-batch", ~s(["done"]), :notice)

    state = :sys.get_state(pid)
    assert [text] = Enum.filter(user_texts(state), &(&1 =~ ~s(["done"])))
    refute text =~ "Message from agent"

    # The delivery is a synchronous `GenServer.call`, but the turn it starts is
    # not: this waits for that turn to end, on the machine's own status (the
    # file's `wait_idle/1`) rather than on the `chat:status` broadcast, so a
    # missed or reordered broadcast can never be the reason it fails. The
    # budget is unchanged: this turn is a single mocked iteration with no tool
    # call and no spawn, and delivery-to-idle measured p50 4.3 ms / max 11.2 ms
    # over 30 samples at 24-way concurrency — ~45x inside the 500 ms fence.
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
    assert List.last(:sys.get_state(pid).live.inbox).content == ~s(["done"])

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
    assert_receive {:DOWN, ^ref, :process, ^gone, :killed}, 500

    assert {:noproc, _reason} =
             catch_exit(Agent.deliver_internal(gone, "agents-batch", "x", :notice))
  end

  test "an over-cap combined message is offloaded to a scratch file and replaced by a pointer", %{
    pid: pid
  } do
    set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "alice", @oversized)

    Agent.stop_chat(pid, self())

    assert Eventually.eventually(
             fn ->
               Enum.any?(
                 user_texts(:sys.get_state(pid)),
                 &(&1 =~ "queued message" and &1 =~ "saved to")
               )
             end,
             timeout: 500
           )

    state = :sys.get_state(pid)

    pointer =
      Enum.find(user_texts(state), &(&1 =~ "queued message" and &1 =~ "saved to"))

    assert pointer =~ "You have 1 queued message"

    [path] = Path.wildcard(Path.join(state.tmp_path, "agent-inbox-*.txt"))
    assert File.read!(path) =~ "hello world"

    wait_idle(pid)
  end

  test "delivery to a broken agent returns an error and queues nothing", %{pid: pid} do
    # intentional: the disposition is the target's status, not the entry's
    # kind — every kind is refused alike, and nothing is queued.
    set_status(pid, :needs_repair)

    for kind <- [:agent, :query, :notice] do
      assert {:error, {:status, :needs_repair}} =
               Agent.deliver_message(pid, "peer", "hello", kind)

      assert :sys.get_state(pid).live.inbox == []
    end
  end

  test "a delivery whose drain parks still broadcasts the queued entry", %{pid: pid} do
    # intentional: the idle path enqueues and drains in one step, and a drain
    # that parks the message (here a `:cannot_compact` block, forced by a
    # context limit nothing can fit) leaves it queued. Without a frame for it
    # the entry's content would be reachable only by a client refetch — the
    # #26 visibility hole. So: whenever the entry is still queued after the
    # drain, a `chat:inbox` frame must have gone out for it.
    :sys.replace_state(pid, fn state ->
      %{state | llm_metrics: %{state.llm_metrics | context_limit: 1}}
    end)

    # The overflow broadcast is the visible half of the block; capture it so the
    # suite's console stays clean and assert it actually happened.
    log =
      capture_log(fn ->
        assert {:ok, :queued} = Agent.deliver_message(pid, "peer", "does not fit")
      end)

    assert log =~ "cannot fit the system prompt"

    state = :sys.get_state(pid)

    assert [%{content: "does not fit", kind: :agent}] = state.live.inbox
    assert_receive {:chat_inbox, %{count: 1}}, 500
    # Nothing was consumed, so the enqueue frame above is the only one: a
    # consume's empty frame would mean the entry had been delivered.
    refute_receive {:chat_inbox, %{count: 0}}, 50
    assert Machine.status_for(state.live.machine) == :context_overflow
  end

  test "delivery is rejected when the inbox is full", %{pid: pid} do
    full =
      for n <- 1..100 do
        %{
          from: "peer",
          content: "msg #{n}",
          timestamp: DateTime.utc_now(),
          kind: :agent,
          mode: nil
        }
      end

    :sys.replace_state(pid, fn state -> %{state | live: %{state.live | inbox: full}} end)

    for kind <- [:agent, :query, :notice] do
      assert {:error, :inbox_full} = Agent.deliver_message(pid, "peer", "one too many", kind)
    end

    assert length(:sys.get_state(pid).live.inbox) == 100
  end

  test "self-delivery is allowed", %{pid: pid, name: name} do
    assert {:ok, :delivered} = Agent.deliver_message(pid, name, "note to self")

    assert Enum.any?(user_texts(:sys.get_state(pid)), &(&1 =~ "note to self"))
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

          state = :sys.get_state(pid)

          assert Enum.any?(
                   user_texts(state),
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
          assert_receive {:chat_status, %{status: "streaming", owedReplies: ["peer"]}}, 500
          wait_idle(pid)
          assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
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
        assert_receive {:chat_inbox, %{count: ^n, messages: messages}}, 500

        assert Enum.map(messages, & &1["kind"]) ==
                 kinds |> Enum.take(n) |> Enum.map(&Atom.to_string/1)
      end

      state = :sys.get_state(pid)

      assert Enum.map(state.live.inbox, & &1.kind) == kinds
      assert Enum.map(state.live.inbox, & &1.from) == ["peer", "peer", "peer"]
      assert Enum.map(state.live.inbox, & &1.mode) == [nil, nil, nil]
      assert Machine.owed_senders(state.live.machine) == []

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

      state = :sys.get_state(pid)
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
      for {status, n} <- Enum.with_index([:streaming, :executing_tools, :compacting], 1) do
        set_status(pid, status)

        assert :ok = Agent.chat(pid, "queued while #{status}", "plan", "alice")

        assert_receive {:chat_inbox, %{count: ^n}}, 500

        state = :sys.get_state(pid)

        assert Machine.status_for(state.live.machine) == status
        assert length(state.live.inbox) == n
      end

      state = :sys.get_state(pid)
      inbox = state.live.inbox

      assert Enum.map(inbox, & &1.kind) == [:user, :user, :user]
      assert Enum.map(inbox, & &1.from) == ["alice", "alice", "alice"]
      assert Enum.map(inbox, & &1.mode) == ["plan", "plan", "plan"]

      assert Enum.map(inbox, & &1.content) == [
               "queued while streaming",
               "queued while executing_tools",
               "queued while compacting"
             ]

      # Queueing is the only effect: no turn started, nothing appended.
      assert Enum.map(state.chat_state.messages, &elem(&1, 0)) == [:system]

      # The fabricated busy status is test-only; leave the agent idle (and
      # the queue empty) so the teardown's zero-in-flight assertion holds.
      reset_to_idle(pid)
    end

    test "a message to an idle agent starts the turn immediately in the requested mode", %{
      pid: pid
    } do
      MockClient.set_response("ok")

      assert :ok = Agent.chat(pid, "hello now", "plan", "alice")

      assert_receive {:chat_status, %{status: "streaming"}}, 500

      state = :sys.get_state(pid)

      assert state.live.inbox == []
      assert state.live.mode == "plan"
      assert Enum.any?(user_texts(state), &(&1 =~ "hello now"))
      assert Enum.any?(user_texts(state), &(&1 =~ "[mode: plan]"))

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "a message to a broken agent is dropped and nothing is queued", %{pid: pid} do
      # intentional: every broken status needs an operator action first; the
      # channel has already told the human why, so the cast is a no-op (it
      # must not fall through to the pipeline).
      log =
        capture_log(fn ->
          for status <- Machine.blocked_phases() do
            set_status(pid, status)
            before = :sys.get_state(pid).chat_state.messages

            assert :ok = Agent.chat(pid, "too late", "plan", "alice")
            _ = :sys.get_state(pid)

            state = :sys.get_state(pid)

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
        before = length(:sys.get_state(pid).chat_state.messages)
        stage_drain(pid, entries)

        Agent.stop_chat(pid, self())

        assert Eventually.eventually(
                 fn -> :sys.get_state(pid).live.inbox == [] end,
                 timeout: 500
               )

        wait_idle(pid)

        delivered =
          :sys.get_state(pid).chat_state.messages
          |> Enum.drop(before)
          |> Enum.filter(&match?({:user, _}, &1))
          |> Enum.map(&mode_of/1)

        assert delivered == expected_modes, label
      end
    end

    test "an over-cap human message is offloaded and delivered as a pointer", %{pid: pid} do
      set_status(pid, :streaming)
      assert :ok = Agent.chat(pid, @oversized, "plan", "alice")
      assert_receive {:chat_inbox, %{count: 1}}, 500

      Agent.stop_chat(pid, self())

      assert Eventually.eventually(
               fn -> :sys.get_state(pid).live.inbox == [] end,
               timeout: 500
             )

      state = :sys.get_state(pid)
      pointer = Enum.find(user_texts(state), &(&1 =~ "queued message"))

      # The human's mode still rides the delivered message, and the oversized
      # content itself is in the scratch file.
      assert pointer =~ "[mode: plan]"
      assert pointer =~ "You have 1 queued message"

      [path] = Path.wildcard(Path.join(state.tmp_path, "agent-inbox-*.txt"))
      assert File.read!(path) =~ "hello world"

      wait_idle(pid)
    end
  end

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

  # Undo a fabricated busy status (and its queued entries) so a test that
  # only inspects the queue leaves the agent idle for the teardown.
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

  # A live turn (so `stop_chat` reaches the idle transition that drains)
  # carrying `entries`, with the mode reset to the vocation default so each
  # drain-mode case starts from a known baseline.
  defp stage_drain(pid, entries) do
    :sys.replace_state(pid, fn state ->
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

  defp entry(kind, from, content, mode \\ nil) do
    %{from: from, content: content, timestamp: DateTime.utc_now(), kind: kind, mode: mode}
  end

  defp wait_idle(pid) do
    assert Eventually.eventually(
             fn ->
               Machine.status_for(:sys.get_state(pid).live.machine) == :idle
             end,
             timeout: 500
           )
  end

  defp user_texts(state) do
    state.chat_state.messages
    |> Enum.flat_map(fn
      {:user, %{parts: parts}} -> [parts_text(parts)]
      _ -> []
    end)
  end

  defp text_of({_tag, %{parts: parts}}), do: parts_text(parts)
  defp text_of(_message), do: ""

  # The `[mode: X]` prefix `Dispatch.build_user_message/2` puts on a delivered
  # message, or nil when the message has none. Any mode name (dashes, uppercase)
  # is accepted, so the helper cannot silently report nil for a real mode.
  defp mode_of(message) do
    case Regex.run(~r/^\[mode: ([^\]]+)\]/, text_of(message)) do
      [_, mode] -> mode
      nil -> nil
    end
  end

  defp parts_text(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end
