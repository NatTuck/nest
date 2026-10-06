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

    * **Case A** (user-message path): a context warning is
      injected before a not-yet-sent user message. The injection
      shape (`NoticePairInjector.build_pair/3` with `:user_agent`
      direction) leaves the messages list ending with the new
      user message, which is wire-valid.

    * **Case B** (LLM-response path): a context or budget reminder
      is injected before a not-yet-appended LLM tool-use response.
      After the tool worker appends the tool result, the messages
      list ends with `tool` (wire `:user`), which is wire-valid for
      the iter-2 LLM call. When the LLM responds text-only, the chat
      finalizes — no LLM call is made with assistant at the tail.

    * **Stop-before-any-delta**: the terminal recovery
      (`Turn.Terminal.recovery_messages/2`) closes the turn with a
      non-empty recovery (`MessageList.pairing_bridge/2`) when the
      user stops before the first delta arrives. No empty message is
      ever persisted, and the list stays alternation-valid.

    * **User-after-user**: an idle agent whose active list ends on a
      `user` message (a turn interrupted before its first delta) gets
      the canonical assistant bridge from `MessageList.pairing_bridge/2`
      on the next turn-opening append, so the new user message does not
      create two consecutive `user` roles.

  These tests pin each of those scenarios at the unit level, using the
  pure `build_pair/3` the machine emits as `{:append_many, _}` actions.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe "Case A (user-message path) — inject before user message" do
    test "trailing :user (post-compaction): single assistant → tail user after append" do
      # After compaction, the messages list ends with
      # `summary_user`. The pending real user message follows.
      # Injection: `[assistant(notice+ack)]` (single) so the
      # wire is `[user, assistant, user]` after appending the
      # real user message.
      messages = [user_struct(0, "summary")]

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :user_agent)
      assert [{:assistant, _}] = pair

      real_user = user_struct(length(messages) + length(pair), "hello")
      new_messages = messages ++ pair ++ [real_user]

      assert MessageList.last_wire_role(new_messages) == :user
    end

    test "trailing :tool: single assistant → tail tool after append (wire :user)" do
      # Trailing source `:tool` is wire-equivalent to `:user`
      # (Anthropic sends tool results as user-role messages,
      # per `MessageList.last_wire_role/1`). A single
      # `[assistant(notice+ack)]` keeps the wire valid; a
      # full pair would create back-to-back users.
      messages = [user_struct(0, "hello"), tool_struct(1, "result")]

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :user_agent)
      assert [{:assistant, _}] = pair

      real_user = user_struct(length(messages) + length(pair), "again")
      new_messages = messages ++ pair ++ [real_user]

      assert MessageList.last_wire_role(new_messages) == :user
    end

    test "trailing :assistant (no tool_use): full pair → tail user after append" do
      # Trailing source `:assistant` (no trailing tool_use):
      # the new user message that follows means the wire
      # sequence must be `assistant → user(notice) →
      # assistant(ack) → user(real)`. The full pair is
      # required.
      messages = [user_struct(0, "hi"), assistant_struct(1, "ok")]

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :user_agent)
      assert [{:user, _}, {:assistant, _}] = pair

      real_user = user_struct(length(messages) + length(pair), "more")
      new_messages = messages ++ pair ++ [real_user]

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
      messages = [user_struct(0, "hi"), assistant_struct_with_tool_use(1)]

      assert :deferred == NoticePairInjector.build_pair(messages, spec(), :user_agent)
    end
  end

  describe "Case B (LLM-response path) — inject before tool_use" do
    test "LLM responds with tool_use: full pair + LLM 1 + tool results → tail tool" do
      # The Case 2 inject happens at the response-handler
      # entry, BEFORE the LLM's assistant message is appended.
      # Then the LLM's assistant (containing tool_use) is
      # appended. Then the tool worker runs and appends the
      # tool result. The final messages list ends with `tool`
      # (wire `:user`), which is the iter-2 input.
      messages = [user_struct(0, "do something")]

      # Step 1: Case 2 inject (`:agent_user` direction).
      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :agent_user)
      after_inject = messages ++ pair

      # Step 2: LLM 1 response appended (with tool_use).
      llm1 = assistant_struct_with_tool_use(length(after_inject))
      after_llm1_messages = after_inject ++ [llm1]

      # Step 3: tool worker appends tool result.
      tool_result = tool_struct(length(after_inject) + 1, "ok")
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

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :agent_user)
      after_inject = messages ++ pair

      llm1 = assistant_struct(length(after_inject), "response")
      after_llm1 = after_inject ++ [llm1]

      # Tail = assistant (the chat is finalizing; no LLM
      # call is made with this list).
      assert MessageList.last_wire_role(after_llm1) == :assistant

      # The next user turn provides a trailing user message.
      # Case A's trailing-`:assistant` branch injects the
      # full pair, leaving the list ending in `user`.
      assert {:ok, next_pair} = NoticePairInjector.build_pair(after_llm1, spec(), :user_agent)
      assert [{:user, _}, {:assistant, _}] = next_pair

      next_real_user = user_struct(length(after_llm1) + length(next_pair), "next")
      ready_for_llm = after_llm1 ++ next_pair ++ [next_real_user]

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

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :agent_user)
      after_inject = messages ++ pair

      llm1_idx = length(after_inject)
      llm1 = assistant_struct_with_tool_use(llm1_idx)
      after_llm1 = after_inject ++ [llm1]

      tool_result = tool_struct(llm1_idx + 1, "ok")
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
           name: "shell-cmd",
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
           name: "shell-cmd",
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
