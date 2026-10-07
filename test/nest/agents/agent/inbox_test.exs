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

    test "combine_and_offload/2 labels each entry by kind and drops a missing/blank sender" do
      # intentional: the combined text is LLM-facing, so a nil or blank sender
      # must read sensibly rather than printing `nil` or `""`.
      entries = [
        entry(:agent, "peer", "from an agent"),
        entry(:user, "alice", "from a human", "plan"),
        entry(:user, nil, "from nobody"),
        entry(:agent, "", "from a blank agent"),
        entry(:user, "", "from a blank human")
      ]

      assert Inbox.combine_and_offload(entries, %Agent{tmp_path: nil}) ==
               "[Message from agent \"peer\"]\nfrom an agent\n\n" <>
                 "[Message from the user \"alice\"]\nfrom a human\n\n" <>
                 "[Message from the user]\nfrom nobody\n\n" <>
                 "[Message from agent]\nfrom a blank agent\n\n" <>
                 "[Message from the user]\nfrom a blank human"
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

    test "drain_mode/1 picks the most recent human mode and ignores the rest" do
      # intentional: every queued entry shares one delivered message, so the
      # mode rule is "most recent human-sourced mode wins, nil means leave
      # the agent's mode alone".
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

    test "a drain applies the most recent human mode and otherwise leaves the agent's mode alone",
         %{pid: pid} do
      # intentional: the mode is applied when the batch is delivered, never
      # when an entry is queued (`state.live.mode` feeds the ongoing turn's
      # `ctx.caps`). `chat` is the vocation default each case starts from, so
      # the expected value proves the rule rather than the previous case.
      cases = [
        {[entry(:agent, "peer", "peer note")], "chat",
         "an agent-only batch keeps the agent's mode"},
        {[entry(:agent, "peer", "peer note"), entry(:user, "alice", "please plan", "plan")],
         "plan", "a human mode applies at drain time"},
        {[
           entry(:user, "alice", "plan please", "plan"),
           entry(:user, "bob", "review please", "review")
         ], "review", "the most recent human mode wins"},
        {[
           entry(:user, "alice", "plan please", "plan"),
           entry(:agent, "peer", "no mode"),
           entry(:user, "bob", "no mode either")
         ], "plan", "a later agent entry or nil mode does not clear it"},
        {[entry(:user, "alice", "bogus please", "bogus")], "chat",
         "an unknown mode falls back to the vocation default, like an idle chat"}
      ]

      for {entries, expected, label} <- cases do
        before = length(:sys.get_state(pid).chat_state.messages)
        stage_drain(pid, entries)

        Agent.stop_chat(pid, self())

        assert Eventually.eventually(
                 fn -> :sys.get_state(pid).live.inbox == [] end,
                 timeout: 500
               )

        state = :sys.get_state(pid)

        assert state.live.mode == expected, label

        delivered =
          state.chat_state.messages |> Enum.drop(before) |> Enum.find(&match?({:user, _}, &1))

        assert text_of(delivered) =~ "[mode: #{expected}]", label

        wait_idle(pid)
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

  defp parts_text(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end
