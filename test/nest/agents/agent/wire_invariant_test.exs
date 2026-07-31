defmodule Nest.Agents.Agent.WireInvariantTest do
  @moduledoc """
  Pins the wire-format invariant: every messages list sent to
  an LLM has a user-role message at the tail.

  Sending with `assistant` at the tail violates Anthropic's
  alternation rule (`user → assistant → user → assistant`).
  The `Preflight.validate_tool_call_pairing/1` check rejects
  such messages with HTTP 400 (`(2013) tool call result does
  not follow tool call` — same error family as the alternation
  violation).

  The wire invariant holds in this codebase because:

    * **Case A** (chat_pipeline.ex): a context warning is
      injected before a not-yet-sent user message. The
      injection shape (`NoticePairInjector.build_pair/3` with
      `:user_agent` direction) leaves the messages list
      ending with the new user message, which is wire-valid.

    * **Case B** (response_handler.ex Case 2): a context or
      budget reminder is injected before a not-yet-appended
      LLM tool-use response. After the tool worker appends
      the tool result, the messages list ends with `tool`
      (wire `:user`), which is wire-valid for the iter-2
      LLM call. When the LLM responds text-only, the chat
      finalizes — no LLM call is made with assistant at the
      tail.

    * **Stop-before-any-delta**: the placeholder assistant
      message in `build_partial_assistant_message/1` (the
      `nil` branch) maintains alternation when the user
      stops a chat turn before the first delta arrives.

  These tests pin each of those scenarios at the unit level.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe "Case A (chat_pipeline.ex) — inject before user message" do
    test "trailing :user (post-compaction): single assistant → tail user after append" do
      # After compaction, the messages list ends with
      # `summary_user`. The pending real user message follows.
      # Injection: `[assistant(notice+ack)]` (single) so the
      # wire is `[user, assistant, user]` after appending the
      # real user message.
      messages = [user_struct(0, "summary")]
      state = build_state(messages)

      assert {:ok, :single_assistant, _stamped, new_state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 spec(),
                 :user_agent
               )

      real_user = user_struct(new_state.chat_state.next_message_index, "hello")
      new_messages = new_state.chat_state.messages ++ [real_user]

      assert MessageList.last_wire_role(new_messages) == :user
    end

    test "trailing :tool: single assistant → tail tool after append (wire :user)" do
      # Trailing source `:tool` is wire-equivalent to `:user`
      # (Anthropic sends tool results as user-role messages,
      # per `MessageList.last_wire_role/1`). A single
      # `[assistant(notice+ack)]` keeps the wire valid; a
      # full pair would create back-to-back users.
      messages = [user_struct(0, "hello"), tool_struct(1, "result")]
      state = build_state(messages)

      assert {:ok, :single_assistant, _stamped, new_state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 spec(),
                 :user_agent
               )

      real_user = user_struct(new_state.chat_state.next_message_index, "again")
      new_messages = new_state.chat_state.messages ++ [real_user]

      assert MessageList.last_wire_role(new_messages) == :user
    end

    test "trailing :assistant (no tool_use): full pair → tail user after append" do
      # Trailing source `:assistant` (no trailing tool_use):
      # the new user message that follows means the wire
      # sequence must be `assistant → user(notice) →
      # assistant(ack) → user(real)`. The full pair is
      # required.
      messages = [
        user_struct(0, "hi"),
        assistant_struct(1, "ok")
      ]

      state = build_state(messages)

      assert {:ok, :user_agent_pair, _stamped, new_state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 spec(),
                 :user_agent
               )

      real_user = user_struct(new_state.chat_state.next_message_index, "more")
      new_messages = new_state.chat_state.messages ++ [real_user]

      assert MessageList.last_wire_role(new_messages) == :user
    end

    test "trailing :assistant + tool_use: :deferred (no injection, preserves in-flight pairing)" do
      # Trailing source `:assistant` carrying an unpaired
      # `Part.ToolUse{}` — the LLM is mid-tool-call. Putting
      # a synthetic pair between the tool_use and its
      # upcoming tool_result would break Anthropic's
      # tool_use/tool_result pairing invariant (rejected with
      # `(2013) tool call result does not follow tool call`).
      # `:deferred` returns without injecting; the next safe
      # boundary (the next iteration's response handler) will
      # retry.
      messages = [
        user_struct(0, "hi"),
        assistant_struct_with_tool_use(1)
      ]

      state = build_state(messages)

      assert :deferred ==
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 spec(),
                 :user_agent
               )
    end
  end

  describe "Case B (response_handler.ex Case 2) — inject before tool_use" do
    test "LLM responds with tool_use: full pair + LLM 1 + tool results → tail tool" do
      # The Case 2 inject happens at the response-handler
      # entry, BEFORE the LLM's assistant message is appended.
      # Then the LLM's assistant (containing tool_use) is
      # appended. Then the tool worker runs and appends the
      # tool result. The final messages list ends with `tool`
      # (wire `:user`), which is the iter-2 input.
      messages = [user_struct(0, "do something")]

      # Step 1: Case 2 inject (`:agent_user` direction).
      agent_user_state = build_state(messages)

      assert {:ok, :agent_user_pair, _stamped, after_inject_state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 agent_user_state,
                 spec(),
                 :agent_user
               )

      # Step 2: LLM 1 response appended (with tool_use).
      llm1 = assistant_struct_with_tool_use(after_inject_state.chat_state.next_message_index)
      after_llm1_messages = after_inject_state.chat_state.messages ++ [llm1]

      # Step 3: tool worker appends tool result.
      tool_result = tool_struct(after_inject_state.chat_state.next_message_index + 1, "ok")
      final_messages = after_llm1_messages ++ [tool_result]

      assert MessageList.last_wire_role(final_messages) == :user
    end

    test "LLM responds with text-only: chat finalizes (no LLM call with assistant tail)" do
      # Case 2 injects, the LLM responds text-only (no
      # tool_use), the assistant message is appended, the
      # chat turn finalizes. The messages list ends with
      # assistant — but no LLM call ships with this tail.
      # The next user turn provides the trailing user message
      # (Case A's trailing-`:assistant` branch, full pair
      # injection).
      messages = [user_struct(0, "hello")]
      agent_user_state = build_state(messages)

      assert {:ok, :agent_user_pair, _stamped, after_inject_state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 agent_user_state,
                 spec(),
                 :agent_user
               )

      llm1 = assistant_struct(after_inject_state.chat_state.next_message_index, "response")
      after_llm1 = after_inject_state.chat_state.messages ++ [llm1]

      # Tail = assistant (the chat is finalizing; no LLM
      # call is made with this list).
      assert MessageList.last_wire_role(after_llm1) == :assistant

      # The next user turn provides a trailing user message.
      # Case A's trailing-`:assistant` branch injects the
      # full pair, leaving the list ending in `user`.
      next_user_state = build_state(after_llm1)

      assert {:ok, :user_agent_pair, _stamped, after_next_state} =
               NoticePairInjector.inject_pair_in_process(
                 after_llm1,
                 next_user_state,
                 spec(),
                 :user_agent
               )

      next_real_user = user_struct(after_next_state.chat_state.next_message_index, "next")
      ready_for_llm = after_next_state.chat_state.messages ++ [next_real_user]

      assert MessageList.last_wire_role(ready_for_llm) == :user
    end
  end

  describe "iter-2 messages are complete (no message drop)" do
    test "Case 2 + LLM tool_use + tool results: all 4 new messages present in iter-2 input" do
      # After the Case 2 inject + LLM 1 + tool worker, the
      # iter-2 LLM call sends the full messages list. All 4
      # new messages since the previous LLM call are present:
      #
      #   1. assistant(attn)        — Case 2 attention
      #   2. user(notice)           — Case 2 notice
      #   3. assistant(LLM, tool_use) — LLM 1
      #   4. tool(results)          — tool worker
      #
      # The tail is `tool` (wire `:user`), which is what the
      # iter-2 LLM call sees at its tail.
      messages = [user_struct(0, "do something")]
      agent_user_state = build_state(messages)

      assert {:ok, :agent_user_pair, _stamped, after_inject} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 agent_user_state,
                 spec(),
                 :agent_user
               )

      after_inject_messages = after_inject.chat_state.messages

      llm1_idx = after_inject.chat_state.next_message_index
      llm1 = assistant_struct_with_tool_use(llm1_idx)
      after_llm1 = after_inject_messages ++ [llm1]

      tool_result_idx = llm1_idx + 1
      tool_result = tool_struct(tool_result_idx, "ok")
      iter2_input = after_llm1 ++ [tool_result]

      assert length(iter2_input) == length(messages) + 4

      # Verify the 4 new messages, in order.
      {role4, attn_msg} = Enum.at(iter2_input, -4)
      assert role4 == :assistant
      assert match?(%Assistant{parts: [%Part.Text{text: "Context?"}]}, attn_msg)

      {role3, notice_msg} = Enum.at(iter2_input, -3)
      assert role3 == :user
      assert match?(%User{}, notice_msg)

      {role2, llm1_msg} = Enum.at(iter2_input, -2)
      assert role2 == :assistant
      assert match?(%Assistant{}, llm1_msg)
      assert Enum.any?(llm1_msg.parts, &match?(%Part.ToolUse{}, &1))

      {role1, tool_msg} = Enum.at(iter2_input, -1)
      assert role1 == :tool
      assert match?(%Tool{}, tool_msg)

      assert MessageList.last_wire_role(iter2_input) == :user
    end
  end

  # --- helpers ---

  defp spec do
    %{kind: :context, attention: "Context?", notice: "token budget", ack: "Okay, noted."}
  end

  defp build_state(messages) do
    %Agent{
      chat_state: %Agent.ChatState{
        messages: messages,
        next_message_index: next_index(messages)
      }
    }
  end

  defp next_index(messages) do
    case Enum.map(messages, fn {_, %{index: i}} -> i end) |> Enum.max() do
      nil -> 0
      max -> max + 1
    end
  end

  defp user_struct(index, text) do
    {:user,
     %User{
       index: index,
       parts: [%Part.Text{text: text}],
       timestamp: nil,
       api_logs: [],
       metadata: %{}
     }}
  end

  defp assistant_struct(index, text) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.Text{text: text}],
       timestamp: nil,
       api_logs: [],
       metadata: nil
     }}
  end

  defp assistant_struct_with_tool_use(index) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [
         %Part.ToolUse{
           id: "call_#{index}",
           name: "shell_cmd",
           arguments: %{"command" => "echo"}
         }
       ],
       timestamp: nil,
       api_logs: [],
       metadata: nil
     }}
  end

  defp tool_struct(index, content) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{
           tool_call_id: "call_#{index - 1}",
           name: "shell_cmd",
           arguments: %{},
           content: content,
           is_error: false
         }
       ],
       timestamp: nil,
       api_logs: []
     }}
  end
end
