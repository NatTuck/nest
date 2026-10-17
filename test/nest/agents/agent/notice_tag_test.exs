defmodule Nest.Agents.Agent.NoticeTagTest do
  @moduledoc """
  The `[nest notice]` marker: which row carries it, and where.

  Every synthetic runtime notice is built from up to three messages, and each
  has its own rule for the marker (`Nest.Messages.NoticeTag`):

    * the synthetic **request** — the attention line (`Context?`, `Tool
      limit?`) — is never tagged;
    * the **notice** is always tagged, at the head of its own text, in every
      injection shape (`NoticePairInjector`) and on the drain's `:notice` path
      (`Inbox.Render`);
    * the synthetic **response** — the ack — is never tagged.

  The enumeration below walks every injection shape against every notice kind,
  so the rule cannot pass by accident: a new shape or kind that forgets the
  marker fails here. The decided notice texts and acks themselves are pinned
  in `ContextReminderTest` and `BudgetReminderTest`; this module pins where the
  marker sits relative to them, and the exact wording of the two kinds the
  marker must wrap without rewording.

  The rows that do not go through the injector are pinned by the test that
  already exercises them end to end: the re-prompt nudge
  (`EmptyResponseRepromptTest`, `MaxTokensContinuationTest`) and the reply
  obligation (`ReplyDebtTest`), both built inside `Machine.Response` /
  `Machine.Compaction`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox.Render
  alias Nest.Agents.Agent.Machine.GiveUp
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Agents.Agent.Turn.Backgrounded
  alias Nest.Agents.Agent.Turn.BudgetReminder
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.WaitForIdle
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.NoticeTag
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @marker "[nest notice]"

  describe "the injector's :agent_user shape" do
    test "tags the notice user row and leaves the attention row untagged" do
      for {label, spec} <- context_specs() ++ budget_specs() do
        assert {:ok, [attention, notice]} =
                 NoticePairInjector.build_pair([], spec, :agent_user)

        assert row_text(attention) == spec.attention, label
        refute tagged?(attention), label

        assert row_text(notice) == NoticeTag.tag(spec.notice), label
      end
    end
  end

  describe "the injector's :user_agent shape" do
    test "tags the fused assistant row, notice and ack together" do
      for {label, spec} <- context_specs() ++ budget_specs(), tail <- [[user(0)], [tool(0)]] do
        assert {:ok, [fused]} = NoticePairInjector.build_pair(tail, spec, :user_agent)

        text = row_text(fused)
        assert String.starts_with?(text, NoticeTag.tag(spec.notice) <> " "), label
        assert tagged?(fused), label
      end
    end

    test "tags the notice row and leaves the ack row untagged on an assistant tail" do
      for {label, spec} <- context_specs() ++ budget_specs() do
        assert {:ok, [notice, ack]} =
                 NoticePairInjector.build_pair([assistant(0)], spec, :user_agent)

        assert row_text(notice) == NoticeTag.tag(spec.notice), label
        refute tagged?(ack), label
      end
    end
  end

  describe "notice_record/3" do
    test "tags the notice row when the record lands the full pair" do
      for {label, {notice, ack}} <- outcome_specs(), tail <- [[assistant(0)], []] do
        assert [{:user, _} = notice_row, {:assistant, _} = ack_row] =
                 NoticePairInjector.notice_record(tail, notice, ack)

        assert row_text(notice_row) == NoticeTag.tag(notice), label
        assert row_text(ack_row) == ack, label
        refute tagged?(ack_row), label
      end
    end

    test "tags the fused assistant row when the record collapses" do
      # A user/tool tail, and the deferred unpaired-`tool_use` tail the
      # appender's terminal bridge repairs, both land the notice and its ack in
      # one assistant message — with the marker at its head.
      for {label, {notice, ack}} <- outcome_specs(),
          tail <- [[user(0)], [tool(0)], [assistant_tool_use(0)]] do
        assert [{:assistant, _} = fused] =
                 NoticePairInjector.notice_record(tail, notice, ack)

        assert row_text(fused) == NoticeTag.tag(notice <> " " <> ack), label
      end
    end
  end

  describe "the drain's :notice entry" do
    test "renders the marker at the head of the notice body" do
      # Every producer that queues a `:notice` entry reaches the same
      # `render_entry/1` clause, so one content per producer is driven here: a
      # backgrounded outcome (its result and its worker's death), a give-up, a
      # sub-agent result and a watch event.
      assert {sub_agent_result, :notice} = SubAgentResults.child_message("kid", {:ok, ""})

      cases = [
        {"a backgrounded result",
         Backgrounded.notice({:results, [%{name: "shell-cmd", content: "done"}]})},
        {"a backgrounded worker's death", Backgrounded.notice({:worker_down, :killed})},
        {"a give-up", GiveUp.notice_text("peer")},
        {"a sub-agent result", sub_agent_result},
        {"a watch event", WaitForIdle.notice_text(%{idle: ["a"], still_busy: [], gone: []})}
      ]

      for {label, content} <- cases do
        assert Render.combine_and_offload([entry(:notice, content)], %Agent{}) ==
                 NoticeTag.tag(content),
               label
      end
    end
  end

  describe "the machine's own notice rows" do
    test "a workspace change and a wire-repair continuation are tagged" do
      # Neither goes through the injector: each builds its own row, so each is
      # pinned here. Both are the runtime speaking, so both carry the marker —
      # without it a user row reads as a human's or a peer's message. The
      # workspace row's `[mode: notice]` prefix comes first (the row's mode is
      # encoded exactly as every delivered row's is), so the marker heads the
      # notice body after it.
      assert [
               {:user, %User{parts: [%Part.Text{text: workspace}]}},
               {:assistant, %Assistant{parts: [%Part.Text{text: ack}]}}
             ] = WorkspaceHandler.notice_pair("/tmp/ws")

      assert workspace == "[mode: notice]\n" <> NoticeTag.tag("Workspace changed to: /tmp/ws")
      assert ack == "Workspace directory change confirmed."

      assert {:user, %User{parts: [%Part.Text{text: continuation}]}} =
               MessageList.continuation_prompt()

      assert continuation ==
               NoticeTag.tag(
                 "An earlier assistant turn did not complete cleanly. Please continue from here."
               )
    end
  end

  describe "the untagged framing" do
    test "the attention texts are unchanged and untagged" do
      assert ContextReminder.spec(40_001, 200_000, MapSet.new()).attention == "Context?"
      assert BudgetReminder.spec(2).attention == "Tool limit?"
    end

    test "the injector's fallback ack is exactly Okay." do
      # `ack_for_kind/1`'s catch-all is reached only by a hand-built spec (in
      # `lib/` every caller puts its ack on the spec), so this is the fixture
      # that pins it.
      spec = %{kind: :something_else, attention: "Attention?", notice: "Notice."}

      assert {:ok, [fused]} = NoticePairInjector.build_pair([user(0)], spec, :user_agent)
      assert row_text(fused) == NoticeTag.tag("Notice. Okay.")
    end
  end

  describe "the wording the marker wraps" do
    test "cancellation and lost keep their own wording, exactly" do
      # These two kinds keep the wording they had before the marker existed:
      # the tag is added around it, never in place of it. Pinned exactly (not by
      # substring) so a later edit cannot quietly reword a promise the model
      # has already been told will not be kept, and both counts are covered
      # because the machine writes one record for a whole stop.
      assert Backgrounded.cancellation(1) ==
               {"The tool call that was running in the background was cancelled when the " <>
                  "conversation was stopped; its result will not arrive.",
                "Understood. I will not wait for it."}

      assert Backgrounded.cancellation(2) ==
               {"The 2 tool calls that were running in the background were cancelled " <>
                  "when the conversation was stopped; their results will not arrive.",
                "Understood. I will not wait for them."}

      assert Backgrounded.lost(1) ==
               {"The backgrounded tool call was lost when this agent restarted; its result " <>
                  "will not arrive. Call it again if you still need it.",
                "Understood. I will not wait for it."}

      assert Backgrounded.lost(2) ==
               {"The 2 backgrounded tool calls were lost when this agent restarted; " <>
                  "their results will not arrive. Call them again if you still need them.",
                "Understood. I will not wait for them."}
    end
  end

  # --- helpers ---

  # Every context kind, one entry per 75% variant, each carrying the ack
  # `Machine.Delivery` would put on its spec.
  defp context_specs do
    for {label, atom, compact?} <- [
          {"context 25%", :p25, true},
          {"context 50%", :p50, true},
          {"context 75% with the tool", :p75, true},
          {"context 75% without the tool", :p75, false}
        ] do
      {label,
       %{
         kind: :context,
         attention: "Context?",
         notice: ContextReminder.notice_text(atom, compact?),
         ack: ContextReminder.ack_text(),
         threshold: atom
       }}
    end
  end

  defp budget_specs do
    for {label, remaining} <- [{"budget, 2 rounds", 2}, {"budget, last round", 1}] do
      {label, BudgetReminder.spec(remaining)}
    end
  end

  # The two notice kinds that close a promise through `notice_record/3`.
  defp outcome_specs do
    [
      {"stop cancellation, one call", Backgrounded.cancellation(1)},
      {"stop cancellation, many calls", Backgrounded.cancellation(3)},
      {"lost promise, one call", Backgrounded.lost(1)},
      {"lost promise, many calls", Backgrounded.lost(3)}
    ]
  end

  defp tagged?({_role, message}), do: String.starts_with?(row_text(message), @marker <> "\n")

  defp row_text({_role, message}), do: row_text(message)

  defp row_text(message) do
    Enum.map_join(message.parts || [], "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end

  defp entry(kind, content) do
    %{
      id: "id-#{kind}",
      from: nil,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: nil,
      human?: false,
      fulfilled_ids: []
    }
  end

  defp user(index) do
    {:user, %User{index: index, parts: [], timestamp: nil, api_logs: [], metadata: %{}}}
  end

  defp tool(index) do
    {:tool, %Tool{index: index, parts: [], timestamp: nil, api_logs: []}}
  end

  defp assistant(index) do
    {:assistant,
     %Assistant{index: index, parts: [%Part.Text{text: "ok"}], timestamp: nil, api_logs: []}}
  end

  defp assistant_tool_use(index) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: "call_#{index}", name: "shell-cmd", arguments: %{}}],
       timestamp: nil,
       api_logs: []
     }}
  end
end
