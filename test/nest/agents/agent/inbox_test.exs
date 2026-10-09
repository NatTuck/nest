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
    set_status(pid, :needs_repair)

    assert {:error, {:status, :needs_repair}} = Agent.deliver_message(pid, "peer", "hello")
    assert :sys.get_state(pid).live.inbox == []
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

    assert {:error, :inbox_full} = Agent.deliver_message(pid, "peer", "one too many")
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

  describe "entry shape and serialization" do
    test "serialize/1 emits the wire shape the browser renders, for both kinds" do
      # intentional: the channel/browser contract is exactly these five
      # keys; `kind` distinguishes a peer from a human and `mode` carries
      # the human's requested mode (nil for an `agents-send` entry).
      at = ~U[2026-01-02 03:04:05Z]

      entries = [
        %{from: "peer", content: "from an agent", timestamp: at, kind: :agent, mode: nil},
        %{from: "alice", content: "from a human", timestamp: at, kind: :user, mode: "plan"},
        %{from: nil, content: "from nobody", timestamp: at, kind: :user, mode: nil}
      ]

      assert Inbox.serialize(entries) == [
               %{
                 "from" => "peer",
                 "content" => "from an agent",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "agent",
                 "mode" => nil
               },
               %{
                 "from" => "alice",
                 "content" => "from a human",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => "plan"
               },
               %{
                 "from" => nil,
                 "content" => "from nobody",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => nil
               }
             ]
    end

    test "batch/1 delivers a human head alone and a leading agent run together" do
      # intentional: a human message is delivered alone — it never merges into
      # a batch and nothing merges into it (issue #31 decision 8) — so a queued
      # human message keeps its own turn and its own mode, while peer traffic
      # still batches. The selection only ever takes a prefix, so the FIFO
      # order is untouched.
      alice = entry(:user, "alice", "human note", "plan")
      peer = entry(:agent, "peer", "peer note")
      bob = entry(:agent, "bob", "second peer note")

      assert Inbox.batch([alice, peer, bob]) == [alice]
      assert Inbox.batch([peer, bob, alice]) == [peer, bob]
      assert Inbox.batch([peer, alice, bob]) == [peer]
      assert Inbox.batch([]) == []

      # A kind that is neither `:agent` nor `:user` — `:query` is what W2
      # introduces — batches with peer entries instead of raising: the
      # selection is total on purpose, so a new entry kind cannot crash the
      # drain inside the Agent process.
      query = %{entry(:agent, "peer", "query note") | kind: :query}

      assert Inbox.batch([query, bob]) == [query, bob]
      assert Inbox.batch([peer, query, alice]) == [peer, query]
    end

    test "combine_and_offload/2 renders a lone human message bare and labels an agent batch" do
      # intentional: the rendered text is LLM-facing. A human entry is its bare
      # content (its `[mode: X]` prefix is added when the message is built), so
      # a queued human message reads exactly like one that arrived while the
      # agent was idle. Agent entries keep `[Message from agent "X"]`, which is
      # what disambiguates a batch; a missing or blank sender drops the quoted
      # name rather than printing `nil` or `""`.
      state = %Agent{tmp_path: nil}

      assert Inbox.combine_and_offload([entry(:user, "alice", "from a human", "plan")], state) ==
               "from a human"

      assert Inbox.combine_and_offload([entry(:user, nil, "from nobody")], state) ==
               "from nobody"

      assert Inbox.combine_and_offload(
               [
                 entry(:agent, "peer", "from an agent"),
                 entry(:agent, "", "from a blank agent"),
                 entry(:agent, nil, "from nobody")
               ],
               state
             ) ==
               "[Message from agent \"peer\"]\nfrom an agent\n\n" <>
                 "[Message from agent]\nfrom a blank agent\n\n" <>
                 "[Message from agent]\nfrom nobody"
    end

    test "enqueue_user_message/4 normalizes a non-binary sender and mode to nil" do
      # intentional: `serialize/1`'s contract is string-or-null, so a malformed
      # payload cannot put a number/map on the wire.
      state = %Agent{name: "wire-shape", space_id: 1}

      state = Inbox.enqueue_user_message(state, %{"not" => "a string"}, "hi", 123)

      assert [%{from: nil, mode: nil, content: "hi", kind: :user}] = state.live.inbox

      assert [serialized] = Inbox.serialize(state.live.inbox)
      assert serialized["from"] == nil
      assert serialized["mode"] == nil
      assert serialized["kind"] == "user"
      assert serialized["content"] == "hi"
      assert is_binary(serialized["timestamp"])
    end

    test "enqueue_internal/4 queues the runtime's own result even at the cap" do
      # intentional: the cap exists to bound a runaway *peer* producer, so the
      # runtime enqueuing its own result (W2's async spawn/batch completion)
      # must never be refused by its own cap — it always queues and broadcasts,
      # exactly like the human path.
      full = for n <- 1..100, do: entry(:agent, "peer", "msg #{n}")
      state = %Agent{name: "internal", space_id: 1}
      state = %{state | live: %{state.live | inbox: full}}
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      state = Inbox.enqueue_internal(state, "runtime", "child finished", :agent)

      assert length(state.live.inbox) == 101
      assert_receive {:chat_inbox, %{count: 101, messages: messages}}
      assert List.last(messages)["content"] == "child finished"

      assert %{from: "runtime", content: "child finished", kind: :agent, mode: nil} =
               List.last(state.live.inbox)
    end

    test "drain_mode/1 picks the most recent human mode and ignores the rest" do
      # intentional: `drain_mode/1` is total over any entry list and returns the
      # most recent human-sourced mode, `nil` meaning "leave the agent's mode
      # alone". A real batch is either a lone human entry or a run of non-human
      # ones (`Inbox.batch/1`), so the mixed lists below are defensive-input
      # coverage for the rule, not a shape a drain can produce.
      assert Inbox.drain_mode([entry(:agent, "peer", "no mode")]) == nil
      assert Inbox.drain_mode([entry(:user, "alice", "plan", "plan")]) == "plan"

      assert Inbox.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:agent, "peer", "no mode"),
               entry(:user, "bob", "review", "review")
             ]) == "review"

      assert Inbox.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:user, "bob", "no mode"),
               entry(:agent, "peer", "no mode")
             ]) == "plan"
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
