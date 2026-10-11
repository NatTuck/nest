defmodule Nest.Agents.Agent.AppendPairingBridgeTest do
  @moduledoc """
  Phase 2 of `notes/enforce-mesages-seq-invariants.md`: append-time
  sequence repair.

  When the live append path is handed a message that would leave the
  trailing assistant's `Part.ToolUse` unpaired (the
  `visual-possum-root` crash), `MessageAppender` first appends and
  persists an `is_error` tool result — plus an assistant
  acknowledgement when the incoming message is a user turn, so
  alternation holds. These tests pin both the pure bridge and the
  canonical append path.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.Turn
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "MessageList.pairing_bridge/2" do
    test "no repair when the tail needs no alternation help" do
      assert [] = MessageList.pairing_bridge([], user(0))
      assert [] = MessageList.pairing_bridge([user(0)], assistant_text(1))
    end

    test "paired tool result + incoming user → assistant ack (tool is wire user)" do
      paired = [assistant_tool_use(0, "call_1"), tool_result(1, "call_1")]

      assert [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}] =
               MessageList.pairing_bridge(paired, user(2))

      assert text =~ "continuing from here"
    end

    test "trailing user + incoming user → assistant ack" do
      messages = [assistant_text(0), user(1)]

      assert [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}] =
               MessageList.pairing_bridge(messages, user(2))

      assert text =~ "continuing from here"
    end

    test "orphan tool_use + incoming user → tool result + assistant ack" do
      messages = [user(0), assistant_tool_use(1, "call_1")]

      assert [tool, ack] = MessageList.pairing_bridge(messages, user(2))
      assert {:tool, %Tool{parts: [%Part.ToolResult{} = result]}} = tool
      assert result.tool_call_id == "call_1"
      assert result.name == "shell-cmd"
      assert result.is_error == true
      assert {:assistant, %Assistant{}} = ack
    end

    test "orphan tool_use + incoming assistant → tool result only (alternation is safe)" do
      messages = [user(0), assistant_tool_use(1, "call_1")]

      assert [{:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_1"}]}}] =
               MessageList.pairing_bridge(messages, assistant_text(2))
    end

    test "a matching tool result is not duplicated" do
      messages = [assistant_tool_use(0, "call_1"), tool_result(1, "call_1")]
      assert [] = MessageList.pairing_bridge(messages, tool_result(2, "call_1"))
    end

    test "multi-tool assistant bridges only the ids the incoming result omits" do
      messages = [assistant_tool_uses(0, ["a", "b"])]

      assert [{:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "b"}]}}] =
               MessageList.pairing_bridge(messages, tool_result(1, "a"))
    end
  end

  describe "MessageList interrupted-tool helpers" do
    test "unpaired_tail_tool_uses/1 reads only a trailing assistant tool call" do
      assert [%Part.ToolUse{id: "a"}, %Part.ToolUse{id: "b"}] =
               MessageList.unpaired_tail_tool_uses([
                 user(0),
                 assistant_tool_uses(1, ["a", "b"])
               ])

      assert MessageList.unpaired_tail_tool_uses([user(0), assistant_text(1)]) == []

      assert MessageList.unpaired_tail_tool_uses([
               assistant_tool_use(0, "a"),
               tool_result(1, "a")
             ]) == []

      assert MessageList.unpaired_tail_tool_uses([]) == []
    end

    test "interrupted_tool_result/1 answers every id with an error result" do
      assert {:tool, %Tool{parts: [a, b]}} =
               MessageList.interrupted_tool_result([
                 %Part.ToolUse{id: "a", name: "shell-cmd", arguments: %{}},
                 %Part.ToolUse{id: "b", name: "file-read", arguments: %{}}
               ])

      assert %Part.ToolResult{tool_call_id: "a", name: "shell-cmd", is_error: true} = a
      assert %Part.ToolResult{tool_call_id: "b", name: "file-read", is_error: true} = b

      assert MessageList.interrupted_tool_result([]) == nil
    end
  end

  describe "MessageList.idle_bridge_ack/1" do
    test "builds a repair_ack-shaped assistant with case-specific wording" do
      assert {:assistant, %Assistant{parts: [%Part.Text{text: compaction}], api_logs: []}} =
               MessageList.idle_bridge_ack(:compaction)

      assert compaction =~ "Compaction complete"

      assert {:assistant, %Assistant{parts: [%Part.Text{text: load}], api_logs: []}} =
               MessageList.idle_bridge_ack(:load)

      assert load =~ "interrupted"

      assert {:assistant, %Assistant{parts: [%Part.Text{text: live}], api_logs: []}} =
               MessageList.idle_bridge_ack(:live)

      assert live =~ "continuing from here"

      # The tag set is closed: an unknown tag must fail loudly with a clear
      # message rather than silently picking a default wording.
      assert_raise ArgumentError, ~r/unknown idle_bridge_ack kind/, fn ->
        MessageList.idle_bridge_ack(:unknown_tag)
      end
    end
  end

  describe "MessageList backgrounded builders" do
    test "backgrounded_tool_result/1 answers every call with a deferred, non-error result" do
      calls = [
        %Part.ToolUse{id: "a", name: "shell-cmd", arguments: %{"timeout" => 300}},
        %Part.ToolUse{id: "b", name: "file-read", arguments: %{}}
      ]

      assert {:tool, %Tool{parts: [a, b]}} = MessageList.backgrounded_tool_result(calls)

      assert %Part.ToolResult{tool_call_id: "a", name: "shell-cmd", is_error: false} = a
      assert a.content =~ "moved to the background"
      assert a.content =~ "arrive later as a message"
      assert a.content =~ "300 seconds"

      assert %Part.ToolResult{tool_call_id: "b", name: "file-read", is_error: false} = b
      assert b.content =~ "declared no timeout"
    end

    test "backgrounded_tool_result/1 accepts preflight ToolCall structs and is nil for []" do
      assert MessageList.backgrounded_tool_result([]) == nil

      call = %Nest.Messages.ToolCall{
        id: "c",
        name: "shell-cmd",
        arguments: %{"timeout" => 5}
      }

      assert {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "c", is_error: false}]}} =
               MessageList.backgrounded_tool_result([call])
    end

    test "backgrounded_ack/0 builds a repair_ack-shaped assistant" do
      assert {:assistant, %Assistant{parts: [%Part.Text{text: text}], api_logs: []}} =
               MessageList.backgrounded_ack()

      assert text =~ "running in the background"
      assert text =~ "arrives as a message"
    end
  end

  describe "Turn.Commit.active_segment/6" do
    test "a compaction that finalizes idle closes on an assistant tail" do
      # The idle invariant: when the commit finalizes (no carried entry,
      # or a carried assistant response), the segment must not end on a
      # user wire role, so the next user turn appends cleanly.
      carried_assistant = assistant_text(nil)

      cases = [
        {nil, [:user, :assistant], :ack},
        {{:assistant_response, carried_assistant, 1, 5}, [:user, :assistant], :carried}
      ]

      for {carried, expected_roles, tail} <- cases do
        {messages, {:compaction, marker}} =
          Turn.Commit.active_segment(commit_state(), "summary", carried, 10, 1, nil)

        assert marker.index == 10
        assert Enum.map(messages, &role/1) == expected_roles, "roles for #{inspect(carried)}"
        assert MessageList.last_wire_role(messages) == :assistant
        assert :ok = Preflight.validate(messages)

        case tail do
          :ack ->
            assert {:assistant, %Assistant{parts: [%Part.Text{text: text}]}} = List.last(messages)
            assert text =~ "Compaction complete"

          :carried ->
            assert List.last(messages) == carried_assistant
        end
      end
    end

    test "a compact_tool carried entry keeps its tool-result tail (resumes generation)" do
      # Regression: a `context-compact`'s carried tail ends on a tool
      # result, whose wire role is `user`. The `{:compact_tool, ...}`
      # entry resumes generation, so this segment is the generation
      # request's input and must keep ending on the tool result. An idle
      # bridge ack here would ship a trailing assistant request (DeepSeek
      # 400s "content[].thinking ... must be passed back"; Anthropic
      # rejects a prefilled assistant when thinking is enabled).
      carried = {:compact_tool, [assistant_tool_use(nil, "c1"), tool_result(nil, "c1")], 1, 5}

      {messages, {:compaction, marker}} =
        Turn.Commit.active_segment(commit_state(), "summary", carried, 10, 1, nil)

      assert marker.index == 10
      assert Enum.map(messages, &role/1) == [:user, :assistant, :tool]
      assert MessageList.last_wire_role(messages) == :user
      assert {:tool, %Tool{}} = List.last(messages)
      assert :ok = Preflight.validate(messages)
      assert :ok = Preflight.validate_request(messages)
    end
  end

  describe "MessageAppender.append_one/2" do
    test "repairs an orphan before a user message and persists the repair" do
      name = unique_name("append-orphan")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)

      {:ok, stamped_user, state} = MessageAppender.append_one(state, user("new question"))

      # Returns only the requested message, stamped at the end.
      assert {:user, %User{index: 5, parts: [%Part.Text{text: "new question"}]}} = stamped_user

      # In-memory sequence: orphan repaired, ack inserted, user last.
      assert Enum.map(state.chat_state.messages, &role/1) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant,
               :user
             ]

      assert Enum.map(state.chat_state.messages, &index/1) == [0, 1, 2, 3, 4, 5]

      assert {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]}} =
               Enum.at(state.chat_state.messages, 3)

      assert :ok = Preflight.validate_tool_call_pairing(state.chat_state.messages)

      # Persisted identically.
      persisted = Persistence.load_messages(test_space_id(), name)
      assert Enum.map(persisted, &index/1) == [0, 1, 2, 3, 4, 5]

      assert Enum.map(persisted, &role/1) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant,
               :user
             ]
    end

    test "adds an assistant ack before a user message appended after a wire-user tail" do
      {:assistant, %Assistant{parts: [%Part.Text{text: ack_text}]}} =
        MessageList.idle_bridge_ack(:live)

      cases = [
        {[system(0), user(1), assistant_tool_use(2, "call_1"), tool_result(3, "call_1")],
         :tool_result},
        {[system(0), user(1)], :interrupted_user}
      ]

      # Both boundaries: the idle (terminal) boundary and the production
      # live shape — `start_chat` flips the machine to `:generating`
      # before the turn-opening append, so the live path must apply the
      # same bridge.
      for {initial, label} <- cases, machine <- [:idle, :streaming] do
        name = unique_name("append-wire-user-#{label}-#{machine}")
        {:ok, _} = Persistence.insert_agent(agent_attrs(name))
        insert_messages(name, initial)

        state = state(name, initial)
        state = if machine == :streaming, do: live(state, :streaming), else: state

        {:ok, stamped_user, state} = MessageAppender.append_one(state, user("next question"))

        assert {:user, %User{}} = stamped_user

        assert Enum.map(state.chat_state.messages, &role/1) ==
                 Enum.map(initial, &role/1) ++ [:assistant, :user],
               "in-memory roles for #{label} (#{machine})"

        assert {:assistant, %Assistant{parts: [%Part.Text{text: ^ack_text}]}} =
                 Enum.at(state.chat_state.messages, -2)

        assert :ok = Preflight.validate(state.chat_state.messages)

        persisted = Persistence.load_messages(test_space_id(), name)

        assert Enum.map(persisted, &role/1) ==
                 Enum.map(initial, &role/1) ++ [:assistant, :user],
               "persisted roles for #{label} (#{machine})"

        assert Enum.map(persisted, &index/1) == Enum.map(state.chat_state.messages, &index/1),
               "persisted indices for #{label} (#{machine})"
      end
    end

    test "does not add messages when the tool result is complete" do
      name = unique_name("append-paired")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)
      {:ok, stamped, state} = MessageAppender.append_one(state, tool_result(nil, "call_1"))

      assert {:tool, %Tool{index: 3}} = stamped
      assert length(state.chat_state.messages) == 4
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2, 3]
    end

    test "sanitizes NUL/invalid UTF-8 before the message reaches state and the DB" do
      name = unique_name("append-sanitize")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1)]
      insert_messages(name, initial)

      state = state(name, initial)

      {:ok, stamped, state} =
        MessageAppender.append_one(state, user("before" <> <<0>> <> "after"))

      assert {:user, %User{parts: [%Part.Text{text: "before\uFFFDafter"}]}} = stamped

      assert {:user, %User{parts: [%Part.Text{text: "before\uFFFDafter"}]}} =
               List.last(state.chat_state.messages)
    end

    test "handle_batch returns repair messages plus the requested ones" do
      name = unique_name("append-batch")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)

      {:ok, stamped, state} =
        MessageAppender.handle_batch(state, [assistant_text(nil), user("real")])

      assert Enum.map(stamped, &index/1) == [3, 4, 5]
      assert Enum.map(stamped, &role/1) == [:tool, :assistant, :user]

      assert Enum.map(state.chat_state.messages, &role/1) == [
               :system,
               :user,
               :assistant,
               :tool,
               :assistant,
               :user
             ]

      assert :ok = Preflight.validate_tool_call_pairing(state.chat_state.messages)

      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [
               0,
               1,
               2,
               3,
               4,
               5
             ]
    end
  end

  describe "MessageAppender live path (a turn owns the sequence)" do
    test "the real tool result lands alone — no synthetic repair" do
      name = unique_name("live-tool-result")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial) |> live(:executing_tools)

      {:ok, stamped, state} = MessageAppender.append_one(state, tool_result(nil, "call_1"))

      assert {:tool, %Tool{index: 3, parts: [%Part.ToolResult{tool_call_id: "call_1"}]}} = stamped

      assert Enum.map(state.chat_state.messages, &role/1) == [:system, :user, :assistant, :tool]

      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2, 3]
    end

    test "a non-result append while a live tool_use is pending is :invalid and dropped" do
      name = unique_name("live-orphan-append")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial) |> live(:executing_tools)

      assert {:invalid, reason, ^state} =
               MessageAppender.append_one(state, user("sneaky user"))

      assert reason =~ "live tool_use"
      assert Enum.map(state.chat_state.messages, &role/1) == [:system, :user, :assistant]
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2]
    end

    test "appending a second consecutive assistant while streaming is :invalid and dropped" do
      name = unique_name("live-alternation")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_text(2)]
      insert_messages(name, initial)

      state = state(name, initial) |> live(:streaming)

      assert {:invalid, reason, ^state} =
               MessageAppender.append_one(state, assistant_text(nil))

      assert reason =~ "second consecutive assistant"
      assert Enum.map(state.chat_state.messages, &role/1) == [:system, :user, :assistant]
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2]
    end

    test "a duplicate/late tool result is :stale and dropped with a warning" do
      name = unique_name("live-stale-result")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      # Tail is an assistant whose tool_use was already answered: the
      # duplicate result does not answer the live tail.
      initial = [
        system(0),
        user(1),
        assistant_tool_use(2, "call_1"),
        tool_result(3, "call_1")
      ]

      insert_messages(name, initial)
      state = state(name, initial) |> live(:streaming)

      log =
        capture_log(fn ->
          assert {:stale, ^state} =
                   MessageAppender.append_one(state, tool_result(nil, "call_1"))
        end)

      assert log =~ "stale append"
      assert Enum.map(state.chat_state.messages, &role/1) == [:system, :user, :assistant, :tool]
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2, 3]
    end
  end

  describe "MessageAppender append ordering" do
    test "persists before broadcasting so the UI never sees an uncommitted row" do
      name = unique_name("append-order")
      test_pid = self()

      Mimic.stub(Nest.Persistence, :insert_message, fn _space, _agent, _message ->
        send(test_pid, :persisted)
        {:ok, :row}
      end)

      Mimic.stub(Nest.Persistence, :update_next_message_index, fn _space, _agent, _index ->
        :ok
      end)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{test_space_id()}:#{name}")

      state = state(name, [system(0), user(1)])
      {:ok, _stamped, _state} = MessageAppender.append_one(state, assistant_text(nil))

      {:messages, messages} = Process.info(self(), :messages)
      persisted_at = Enum.find_index(messages, &(&1 == :persisted))
      broadcast_at = Enum.find_index(messages, &match?({:chat_message, _}, &1))

      assert is_integer(persisted_at)
      assert is_integer(broadcast_at)
      assert persisted_at < broadcast_at
    end
  end

  describe "stale tool-result guard" do
    test "drops a late result when an earlier result already answered the call" do
      name = unique_name("stale-tool-result")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1"), tool_result(3, "call_1")]
      insert_messages(name, initial)

      # The machine is idle: a late result for call_1 would be an orphan.
      # It must be dropped, not appended.
      state = state(name, initial)

      assert {:ok, final} = Turn.settle(state, {:tool_results, make_ref(), []})

      assert Enum.map(final.chat_state.messages, &role/1) == [:system, :user, :assistant, :tool]
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2, 3]
    end

    test "drops a late result when the tail is a recovery acknowledgement" do
      name = unique_name("stale-after-ack")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [
        system(0),
        user(1),
        assistant_tool_use(2, "call_1"),
        tool_result(3, "call_1"),
        assistant_text(4)
      ]

      insert_messages(name, initial)

      state = state(name, initial)

      assert {:ok, _final} = Turn.settle(state, {:tool_results, make_ref(), []})

      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [
               0,
               1,
               2,
               3,
               4
             ]
    end
  end

  # ---- helpers ----

  # The minimal `Agent.t()` `Turn.Commit.active_segment/6` reads: the
  # archived messages, the compaction counter, and the context limit.
  defp commit_state do
    %Agent{
      chat_state: %Agent.ChatState{messages: [user(0)], compaction_count: 0},
      llm_metrics: %Agent.LlmMetrics{context_limit: 100_000}
    }
  end

  defp state(name, messages) do
    %Agent{
      name: name,
      space_id: test_space_id(),
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{messages: messages, next_message_index: next_index(messages)}
    }
  end

  defp live(state, status) do
    %{
      state
      | live: %{
          state.live
          | machine: Machine.status_to_machine(state.live.machine, status)
        }
    }
  end

  defp insert_messages(name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(test_space_id(), name, message)
    end
  end

  defp next_index([]), do: 0

  defp next_index(messages) do
    messages |> Enum.map(&index/1) |> Enum.max() |> Kernel.+(1)
  end

  defp index({_role, %{index: idx}}), do: idx
  defp role({role, _}), do: role

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(text) when is_binary(text),
    do: {:user, %User{index: nil, parts: [%Part.Text{text: text}]}}

  defp user(index), do: {:user, %User{index: index, parts: [%Part.Text{text: "hi"}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool_use(index, id),
    do: assistant_tool_uses(index, [id])

  defp assistant_tool_uses(index, ids) do
    parts =
      Enum.map(ids, fn id ->
        %Part.ToolUse{id: id, name: "shell-cmd", arguments: %{"command" => "x"}}
      end)

    {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
  end

  defp tool_result(index, id) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: "ok", is_error: false}
       ],
       api_logs: []
     }}
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
