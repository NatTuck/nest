defmodule Nest.Agents.Agent.Turn.CommitTest do
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.LlmMetrics
  alias Nest.Agents.Agent.Turn.Commit
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe "active_segment/6 and the idle bridge ack" do
    test "a compact_tool carried entry keeps its tool-result tail (no bridge ack)" do
      # Regression: a context-compact's carried tail ends on a tool
      # result (wire role user). Appending the idle bridge ack there
      # would turn the resumed generation request into one whose final
      # message is a synthetic assistant with no thinking block —
      # DeepSeek 400s ("content[].thinking ... must be passed back") and
      # Anthropic rejects a prefilled assistant under thinking.
      {new_messages, _marker} = active_segment({:compact_tool, [assistant(), tool()], 0, 10})

      assert MessageList.last_wire_role(new_messages) == :user
      refute Enum.any?(new_messages, &bridge_ack?/1)
      assert Preflight.validate_request(new_messages) == :ok
    end

    test "a user_message carried entry keeps its user tail (no bridge ack)" do
      {new_messages, _marker} =
        active_segment({:user_message, user("hello")})

      assert MessageList.last_wire_role(new_messages) == :user
      refute Enum.any?(new_messages, &bridge_ack?/1)
    end

    test "a nil carried entry appends the idle bridge ack" do
      # No carried entry means the segment finalizes idle, so it must
      # end on an assistant (the idle invariant).
      {new_messages, _marker} = active_segment(nil)

      assert MessageList.last_wire_role(new_messages) == :assistant
      assert Enum.any?(new_messages, &bridge_ack?/1)
    end

    test "an assistant_response carried entry ends on the assistant (no bridge ack)" do
      {new_messages, _marker} = active_segment({:assistant_response, text_assistant(), 0, 10})

      assert MessageList.last_wire_role(new_messages) == :assistant
      refute Enum.any?(new_messages, &bridge_ack?/1)
    end
  end

  defp active_segment(carried_entry) do
    Commit.active_segment(state(), "the summary", carried_entry, 5, 20, nil)
  end

  defp state do
    %Agent{
      name: "a",
      space_id: 1,
      chat_state: %ChatState{messages: [], compaction_count: 0},
      llm_metrics: %LlmMetrics{context_limit: 100_000, context_limit_source: :default}
    }
  end

  defp assistant do
    {:assistant,
     %Assistant{
       index: nil,
       parts: [
         %Part.Thinking{thinking: "let me compact", signature: "sig"},
         %Part.Text{text: "Compacting."},
         %Part.ToolUse{id: "c1", name: "context-compact", arguments: %{}}
       ],
       usage: nil,
       api_logs: []
     }}
  end

  defp text_assistant do
    {:assistant, %Assistant{index: nil, parts: [%Part.Text{text: "done"}], api_logs: []}}
  end

  defp tool do
    {:tool,
     %Tool{
       index: nil,
       parts: [
         %Part.ToolResult{
           tool_call_id: "c1",
           name: "context-compact",
           content: "Compacted from 1000 token previous context.",
           is_error: false
         }
       ],
       api_logs: []
     }}
  end

  defp user(text) do
    {:user, %User{index: nil, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp bridge_ack?({:assistant, %Assistant{parts: [%Part.Text{text: text}]}}),
    do: String.starts_with?(text, "Compaction complete")

  defp bridge_ack?(_message), do: false
end
