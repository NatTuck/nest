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

  import Nest.PersistenceTestHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence

  describe "MessageList.pairing_bridge/2" do
    test "no repair when the tail is not an assistant tool call" do
      assert [] = MessageList.pairing_bridge([user(0)], user(1))
      assert [] = MessageList.pairing_bridge([], user(0))

      paired = [assistant_tool_use(0, "call_1"), tool_result(1, "call_1")]
      assert [] = MessageList.pairing_bridge(paired, user(2))
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

  describe "MessageAppender.append_one/2" do
    test "repairs an orphan before a user message and persists the repair" do
      name = unique_name("append-orphan")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)

      {stamped_user, state} = MessageAppender.append_one(state, user("new question"))

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

    test "does not add messages when the tool result is complete" do
      name = unique_name("append-paired")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)
      {stamped, state} = MessageAppender.append_one(state, tool_result(nil, "call_1"))

      assert {:tool, %Tool{index: 3}} = stamped
      assert length(state.chat_state.messages) == 4
      assert Enum.map(Persistence.load_messages(test_space_id(), name), &index/1) == [0, 1, 2, 3]
    end

    test "handle_batch returns repair messages plus the requested ones" do
      name = unique_name("append-batch")
      {:ok, _} = Persistence.insert_agent(agent_attrs(name))

      initial = [system(0), user(1), assistant_tool_use(2, "call_1")]
      insert_messages(name, initial)

      state = state(name, initial)

      {stamped, state} =
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

  # ---- helpers ----

  defp state(name, messages) do
    %Agent{
      name: name,
      space_id: test_space_id(),
      llm_metrics: %Agent.LlmMetrics{context_limit: 100_000, context_limit_source: :config},
      chat_state: %Agent.ChatState{messages: messages, next_message_index: next_index(messages)}
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
