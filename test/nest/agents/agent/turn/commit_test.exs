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

  describe "the post-compaction active segment" do
    test "a compact_resume carried entry carries no tail and gets no bridge ack" do
      # A `context-compact` call and its synthetic result are persisted before
      # the compaction request, so they belong to the archived segment and the
      # entry carries no messages. It must still suppress the idle bridge ack:
      # generation resumes on the far side of the commit, and a segment ending
      # on a synthetic assistant is a prefilled-assistant request (DeepSeek 400s
      # "content[].thinking ... must be passed back"; Anthropic rejects it when
      # thinking is enabled).
      {new_messages, _marker} = active_segment({:compact_resume, 0, 10})

      assert [{:user, %User{}}] = new_messages
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

  describe "the post-compaction summary message" do
    test "names what was replaced, carries preserve verbatim, and points at the archive" do
      {[summary], {:compaction, marker}} =
        active_segment_with_preserve("the summary text", "PRESERVED: task and state")

      assert {:user, %User{parts: [%Part.Text{text: text}]}} = summary

      # The count is the marker's own, so one event cannot report two numbers.
      header =
        "Summary of previous conversation (compacted from #{marker.tokens_compacted} tokens):"

      assert text =~ header

      # The agent's own content. The machinery writes it, not the compactor, so
      # it survives whatever the compactor returned.
      assert text =~ "PRESERVED: task and state"

      # The compactor's prose, and where the rest of the conversation went.
      assert text =~ "the summary text"
      assert text =~ "`agents-history` (start_index 0, length 5)"
    end

    test "an absent preserve leaves no empty section" do
      {[summary], _marker} = active_segment_with_preserve("the summary text", nil)
      assert {:user, %User{parts: [%Part.Text{text: text}]}} = summary

      assert text =~ "the summary text"
      refute text =~ "\n\n\n"
    end
  end

  defp active_segment(carried_entry) do
    Commit.active_segment(state(), "the summary", nil, carried_entry, 5, 20, nil)
  end

  # `{:compact_resume, 0, 10}` carries no messages and suppresses the idle
  # bridge ack, so the segment is exactly the summary row — the shape a
  # `context-compact` commit produces.
  defp active_segment_with_preserve(summary_text, preserve) do
    Commit.active_segment(
      state_with_archived_messages(),
      summary_text,
      preserve,
      {:compact_resume, 0, 10},
      5,
      20,
      nil
    )
  end

  # A state with something in the active segment, so the header's token count is
  # a real estimate rather than the empty list's zero. The segment is shaped like
  # the one a `context-compact` call produces: a user row, then the call and its
  # synthetic result.
  defp state_with_archived_messages do
    %{
      state()
      | chat_state: %ChatState{
          messages: [user("First"), assistant(), tool()],
          compaction_count: 0
        }
    }
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
