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

  This file judges the *composed* lists by that real rule set
  (`Preflight.validate/1`) rather than by the pair's row shapes:
  `HeaderTest` pins the shapes and which row carries the runtime header,
  and `NoticePairInjectorTest` pins the deferral and ack decisions. What
  is left here is the `:user_agent` direction's branch per trailing role,
  its refusal (`:deferred`) on an unpaired `tool_use` tail, and the
  `:agent_user` pair landing before the LLM's own response in the iter-2
  input with nothing dropped.

  The wire invariant holds in this codebase because:

    * **Case A** (user-message path): a context warning is
      injected before a not-yet-sent user message. The injection
      shape (`NoticePairInjector.build_pair/3` with `:user_agent`
      direction) leaves the messages list ending with the new
      user message, which is wire-valid. The branch is chosen by the
      *trailing* role, and each branch is pinned below.

    * **Case B** (LLM-response path): a context or budget reminder
      is injected before a not-yet-appended LLM tool-use response.
      After the tool worker appends the tool result, the messages
      list ends with `tool` (wire `:user`), which is wire-valid for
      the iter-2 LLM call. When the LLM responds text-only, the chat
      finalizes — no LLM call is made with assistant at the tail.
      That composition is pinned end to end: every outgoing request
      passes `MockClient`'s `Preflight` check.

    * **Stop-before-any-delta** and **user-after-user**: pinned in
      `MessageAppendTagsTest` and `AppendPairingBridgeTest`, where the
      appender and the terminal recovery actually run.

  These tests use the pure `build_pair/3` the machine emits as
  `{:append_many, _}` actions.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe "Case A (user-message path) — inject before user message" do
    test "trailing :user (post-compaction): bridge, notice, ack → tail user after append" do
      # After compaction, the messages list ends with
      # `summary_user`. The pending real user message follows.
      # The notice is a user row, so the injection opens with the
      # alternation bridge: `[assistant(bridge), user(notice),
      # assistant(ack)]`, making the wire
      # `[user, assistant, user, assistant, user]` after appending
      # the real user message.
      messages = [user_struct(0, "summary")]

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :user_agent)
      assert [{:assistant, _}, {:user, _}, {:assistant, _}] = pair

      real_user = user_struct(length(messages) + length(pair), "hello")
      new_messages = messages ++ pair ++ [real_user]

      assert Preflight.validate(new_messages) == :ok
    end

    test "trailing :tool: bridge, notice, ack → tail tool after append (wire :user)" do
      # Trailing source `:tool` is wire-equivalent to `:user`
      # (Anthropic sends tool results as user-role messages,
      # per `MessageList.last_wire_role/1`), so it takes the same
      # bridge as a `:user` tail: a user-role notice on a wire-user
      # tail would be two consecutive user roles.
      #
      # The fixture pairs its tool result with a real `tool_use` so the
      # composed list is one `Preflight.validate/1` can actually judge.
      messages = [
        user_struct(0, "hello"),
        assistant_struct_with_tool_use(1),
        tool_struct(2, "result")
      ]

      assert {:ok, pair} = NoticePairInjector.build_pair(messages, spec(), :user_agent)
      assert [{:assistant, _}, {:user, _}, {:assistant, _}] = pair

      real_user = user_struct(length(messages) + length(pair), "again")
      new_messages = messages ++ pair ++ [real_user]

      assert Preflight.validate(new_messages) == :ok
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

      assert Preflight.validate(new_messages) == :ok
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

      # Exactly the four new messages, and the pair is the two rows the
      # LLM's own response follows.
      assert length(iter2_input) == length(messages) + 4

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Context?"}]}} =
               Enum.at(iter2_input, -4)

      assert {:user, _} = Enum.at(iter2_input, -3)
    end
  end

  # --- helpers ---

  defp spec do
    %{
      kind: :context,
      attention: "Context?",
      notice: "token budget",
      ack: "Okay, context noted.",
      mode: "act"
    }
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
