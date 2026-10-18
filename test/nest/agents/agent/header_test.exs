defmodule Nest.Agents.Agent.HeaderTest do
  @moduledoc """
  The `[From … | mode: …]` header: which row carries it, and what it says.

  Every **user-role** row states its sender and the recipient's mode
  (`Nest.Messages.Header`). A batch states each body's sender; a single-sender
  row states it once; the synthetic rows that frame a notice — the attention
  line, the alternation bridge, the acknowledgement — carry no header at all,
  because they are not messages from anyone.

  The enumeration below walks every producer against every notice kind, so the
  rule cannot pass by accident: a producer that forgets the header, or a
  framing row that grows one, fails here. The decided notice texts and acks
  themselves are pinned in `ContextReminderTest` and `BudgetReminderTest`; this
  module pins where the header sits relative to them, and the exact wording of
  the two kinds a header must wrap without rewording.

  The rows that do not go through the injector are pinned by the test that
  already exercises them end to end: the re-prompt nudge
  (`EmptyResponseRepromptTest`, `MaxTokensContinuationTest`), the reply
  obligation (`ReplyDebtTest`) and the drain's own rendering (`InboxRenderTest`).
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
  alias Nest.Messages.Header
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @runtime_header "[From nest runtime | mode: act]"

  describe "the injector's :agent_user shape" do
    test "headers the notice row and leaves the attention row bare" do
      for {label, spec} <- context_specs() ++ budget_specs() do
        assert {:ok, [attention, notice]} =
                 NoticePairInjector.build_pair([], spec, :agent_user)

        assert row_text(attention) == spec.attention, label
        refute headered?(attention), label

        assert header_of(notice) == @runtime_header, label
        assert body_of(notice) == spec.notice, label
      end
    end
  end

  describe "the injector's :user_agent shape" do
    test "headers the notice row and leaves the bridge and ack bare" do
      for {label, spec} <- context_specs() ++ budget_specs(), tail <- [[user(0)], [tool(0)]] do
        assert {:ok, [bridge, notice, ack]} =
                 NoticePairInjector.build_pair(tail, spec, :user_agent)

        refute headered?(bridge), label
        assert {:user, _} = notice
        assert header_of(notice) == @runtime_header, label
        assert body_of(notice) == spec.notice, label
        refute headered?(ack), label
      end
    end

    test "headers the notice row and leaves the ack row bare on an assistant tail" do
      for {label, spec} <- context_specs() ++ budget_specs() do
        assert {:ok, [notice, ack]} =
                 NoticePairInjector.build_pair([assistant(0)], spec, :user_agent)

        assert header_of(notice) == @runtime_header, label
        assert body_of(notice) == spec.notice, label
        refute headered?(ack), label
      end
    end
  end

  describe "notice_record/3" do
    test "headers the notice row when the record lands the full pair" do
      for {label, {notice, ack}} <- outcome_specs(), tail <- [[assistant(0)], []] do
        assert [{:user, _} = notice_row, {:assistant, _} = ack_row] =
                 NoticePairInjector.notice_record(tail, notice, ack, "act")

        assert header_of(notice_row) == @runtime_header, label
        assert body_of(notice_row) == notice, label
        assert row_text(ack_row) == ack, label
        refute headered?(ack_row), label
      end
    end

    test "headers the notice row when the record has to bridge" do
      for {label, {notice, ack}} <- outcome_specs(),
          tail <- [[user(0)], [tool(0)], [assistant_tool_use(0)]] do
        assert [{:assistant, _} = bridge, {:user, _} = notice_row, {:assistant, _} = ack_row] =
                 NoticePairInjector.notice_record(tail, notice, ack, "act")

        refute headered?(bridge), label
        assert header_of(notice_row) == @runtime_header, label
        assert body_of(notice_row) == notice, label
        assert row_text(ack_row) == ack, label
        refute headered?(ack_row), label
      end
    end
  end

  describe "the drain's :runtime entry" do
    test "renders the runtime header at the head of the notice body" do
      # Every producer that queues a `:runtime` entry reaches the same
      # `render_entry/1` clause, so one content per producer is driven here: a
      # backgrounded outcome (its result and its worker's death), a give-up, a
      # sub-agent result and a watch event.
      assert {sub_agent_result, :runtime} = SubAgentResults.child_message("kid", {:ok, ""})

      cases = [
        {"a backgrounded result",
         Backgrounded.notice({:results, [%{name: "shell-cmd", content: "done"}]})},
        {"a backgrounded worker's death", Backgrounded.notice({:worker_down, :killed})},
        {"a give-up", GiveUp.notice_text("peer")},
        {"a sub-agent result", sub_agent_result},
        {"a watch event", WaitForIdle.notice_text(%{idle: ["a"], still_busy: [], gone: []})}
      ]

      for {label, content} <- cases do
        agent = %Agent{live: %Agent.ChatState.Live{mode: "act"}}

        assert Render.combine_and_offload([entry(:runtime, content)], agent) ==
                 Header.put(content, :runtime, "act"),
               label
      end
    end
  end

  describe "the machine's own notice rows" do
    test "a space-environment change and a wire-repair continuation carry the runtime header" do
      # Neither goes through the injector: each builds its own row, so each is
      # pinned here. Both are the runtime speaking, so both carry its header —
      # without it a user row reads as a human's or a peer's message.
      assert [
               {:user, %User{parts: [%Part.Text{text: notice}], metadata: metadata}},
               {:assistant, %Assistant{parts: [%Part.Text{text: ack}]}}
             ] =
               WorkspaceHandler.notice_pair(
                 %{workspace: "/tmp/ws", network_access: true, backend: "bwrap"},
                 "act"
               )

      assert metadata == %{"mode" => "act"}
      assert header_of({:user, %User{parts: [%Part.Text{text: notice}]}}) == @runtime_header

      assert notice ==
               @runtime_header <>
                 "\nThis space's environment changed. Workspace: /tmp/ws. " <>
                 "Network access: enabled. Sandbox: bwrap. " <>
                 "The `plan` restriction is enforced here: a write outside the " <>
                 "scratch directory fails."

      assert ack == "Space environment change confirmed."

      assert {:user, %User{parts: [%Part.Text{text: continuation}], metadata: continuation_meta}} =
               MessageList.continuation_prompt("act")

      assert continuation_meta == %{"mode" => "act"}

      assert continuation ==
               @runtime_header <>
                 "\nAn earlier assistant turn did not complete cleanly. Please continue from here."
    end
  end

  describe "the bare framing" do
    test "the attention texts are unchanged and unheadered" do
      assert ContextReminder.spec(40_001, 200_000, MapSet.new()).attention == "Context?"
      assert BudgetReminder.spec(2).attention == "Tool limit?"
    end

    test "the injector's fallback ack is exactly Okay." do
      # `ack_for_kind/1`'s catch-all is reached only by a hand-built spec (in
      # `lib/` every caller puts its ack on the spec), so this is the fixture
      # that pins it.
      spec = %{kind: :something_else, attention: "Attention?", notice: "Notice.", mode: "act"}

      assert {:ok, [_bridge, notice, ack]} =
               NoticePairInjector.build_pair([user(0)], spec, :user_agent)

      assert body_of(notice) == "Notice."
      assert row_text(ack) == "Okay."
    end
  end

  describe "the wording the header wraps" do
    test "cancellation and lost keep their own wording, exactly" do
      # These two kinds keep the wording they had before the header existed: the
      # header is added around it, never in place of it. Pinned exactly (not by
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

  describe "the readers" do
    test "runtime?/1 matches the sender, whatever the rest of the header says" do
      assert Header.runtime?("[From nest runtime | mode: act]")

      # Unreachable today — the reply marker is set from `kind == :query`, and a
      # query's sender is an agent — but that invariant lives in `Inbox.Render`,
      # not here, and a reader that under-counts would let the retry bound in
      # `Machine.Response` allow a re-prompt indefinitely.
      assert Header.runtime?("[From nest runtime, agents-send reply required | mode: act]")

      refute Header.runtime?("[From agent peer | mode: act]")
      refute Header.runtime?("[From user | mode: act]")
      refute Header.runtime?("no header at all")
    end

    test "body/1 is the text behind a header, and nil without one" do
      assert Header.body("[From user | mode: act]\nhello") == "hello"
      assert Header.body("[From nest runtime | mode: act]\n\nmulti\nline") == "\nmulti\nline"

      # No header: the whole text, unchanged (and the caller is told so).
      assert Header.body("no header") == nil

      # A header is a whole line. Text that merely starts with the opening is
      # not one, and it must not be truncated.
      assert Header.body("[From the top] of my head") == nil
    end
  end

  describe "sender/3" do
    test "names a human when the sender is an address, and only then" do
      # The sigil is what says the words are a human's, and it carries the
      # address the recipient answers to: a note from `@nat` is the one the
      # agent must answer, and `@nat` is what it answers to.
      assert Header.sender("@nat", false, :query) == {:user, "nat"}

      assert Header.line(Header.sender("@nat", false, :query), "act", true) ==
               "[From user @nat, agents-send reply required | mode: act]"

      # A bare name is an agent's, whatever the `human?` flag says about who
      # typed it: the chat channel passes the socket's username with no sigil,
      # and that row is a human's with no address to state.
      assert Header.sender("nat", true) == :user
      assert Header.sender("nat", false) == {:agent, "nat"}

      # The runtime's own words are the runtime's whatever agent they are about.
      assert Header.sender("crazy-dolphin", false, :runtime) == :runtime
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
         threshold: atom,
         mode: "act"
       }}
    end
  end

  defp budget_specs do
    for {label, remaining} <- [{"budget, 2 rounds", 2}, {"budget, last round", 1}] do
      {label, Map.put(BudgetReminder.spec(remaining), :mode, "act")}
    end
  end

  # The two notice kinds that close a promise through `notice_record/4`.
  defp outcome_specs do
    [
      {"stop cancellation, one call", Backgrounded.cancellation(1)},
      {"stop cancellation, many calls", Backgrounded.cancellation(3)},
      {"lost promise, one call", Backgrounded.lost(1)},
      {"lost promise, many calls", Backgrounded.lost(3)}
    ]
  end

  defp headered?({_role, message}), do: String.starts_with?(row_text(message), "[From ")

  # The header line, or nil when the row has none.
  defp header_of({_role, message}) do
    case String.split(row_text(message), "\n", parts: 2) do
      [line, _rest] -> if String.starts_with?(line, "[From "), do: line
      _ -> nil
    end
  end

  # The row's text with its header line removed.
  defp body_of({_role, message}) do
    case String.split(row_text(message), "\n", parts: 2) do
      [_header, body] -> body
      [body] -> body
    end
  end

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
