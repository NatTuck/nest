defmodule Nest.Agents.Agent.NoticePairInjectorTest do
  @moduledoc """
  Tests for `NoticePairInjector.build_pair/3` — the pure, wire-safe
  synthetic notice-pair builder the machine's user-message and
  LLM-response paths both use.

  Coverage:
    * shape selection for every (direction, trailing role) combination;
    * wire-safety: the chosen pair preserves the user/assistant
      alternation Anthropic and OpenAI require;
    * `:deferred` when a trailing unpaired `tool_use` makes injection
      unsafe.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe ":agent_user direction" do
    test "builds [assistant(attention), user(notice)] with the spec threshold metadata" do
      assert {:ok, [first, second]} = NoticePairInjector.build_pair([], spec(), :agent_user)

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Context?"}]}} = first

      assert {:user,
              %User{
                parts: [%Part.Text{text: "Notice."}],
                metadata: %{"context_threshold" => "p25"}
              }} = second
    end

    test "defers when the trailing assistant carries an unpaired tool_use" do
      assert :deferred ==
               NoticePairInjector.build_pair([assistant_tool_use(0)], spec(), :agent_user)
    end
  end

  describe ":user_agent direction" do
    test "trailing :user builds a single [assistant(notice + ack)]" do
      assert {:ok, [{:assistant, %Assistant{parts: [%Part.Text{text: "Notice. Ack."}]}}]} =
               NoticePairInjector.build_pair([user(0)], spec(), :user_agent)
    end

    test "trailing :user with a budget spec defaults the ack" do
      spec = %{kind: :budget, attention: "Tool limit?", notice: "Last round."}

      assert {:ok,
              [{:assistant, %Assistant{parts: [%Part.Text{text: "Last round. Okay, noted."}]}}]} =
               NoticePairInjector.build_pair([user(0)], spec, :user_agent)
    end

    test "trailing :tool builds a single [assistant(notice + ack)]" do
      # Trailing :tool is wire-equivalent to :user; a full pair would
      # create back-to-back users.
      assert {:ok, [{:assistant, _}]} =
               NoticePairInjector.build_pair([tool(0)], spec(), :user_agent)
    end

    test "trailing :assistant (no tool_use) builds [user(notice), assistant(ack)]" do
      assert {:ok,
              [
                {:user, %User{parts: [%Part.Text{text: "Notice."}]}},
                {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
              ]} = NoticePairInjector.build_pair([assistant(0)], spec(), :user_agent)
    end

    test "defers when the trailing assistant carries an unpaired tool_use" do
      assert :deferred ==
               NoticePairInjector.build_pair([assistant_tool_use(0)], spec(), :user_agent)
    end
  end

  describe "notice_record/3" do
    test "collapses to one assistant message when the tail is user or tool" do
      # A user-role notice on a wire-user tail is two consecutive user roles, so
      # the appender's terminal bridge would insert an alternation ack of its own
      # — the record would close with two acknowledgements. The collapsed shape
      # is the same `:user_agent` rule `build_pair/3` uses, and lands the notice
      # and its acknowledgement in one message.
      for messages <- [[user(0)], [tool(0)]] do
        assert [{:assistant, %Assistant{parts: [%Part.Text{text: "Notice. Ack."}]}}] =
                 NoticePairInjector.notice_record(messages, "Notice.", "Ack.")
      end
    end

    test "lands the full pair when the tail is an assistant or nothing at all" do
      # An empty list has no tail to alternate with, so the pair is wire-legal
      # there too (`[user, assistant]` is the opening shape of any conversation).
      for messages <- [[assistant(0)], []] do
        assert [
                 {:user, %User{parts: [%Part.Text{text: "Notice."}]}},
                 {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
               ] = NoticePairInjector.notice_record(messages, "Notice.", "Ack.")
      end
    end

    test "resolves a deferred tail to one assistant message the bridge repairs without an ack" do
      # `build_pair/3` defers on an unpaired `tool_use` tail, because a caller
      # there has a next safe boundary to retry at. A record that must land now
      # does not, so it collapses to the single assistant message: the appender's
      # terminal bridge answers the unpaired ids before it lands, and fabricates
      # no acknowledgement of its own (its incoming message is an assistant).
      messages = [assistant_tool_use(0)]

      assert [{:assistant, _} = record] =
               NoticePairInjector.notice_record(messages, "Notice.", "Ack.")

      assert [
               {:tool,
                %Tool{
                  parts: [%Part.ToolResult{tool_call_id: "call_0", is_error: true}]
                }}
             ] = MessageList.pairing_bridge(messages, record)
    end
  end

  # --- helpers ---

  defp spec do
    %{kind: :context, attention: "Context?", notice: "Notice.", ack: "Ack.", threshold: :p25}
  end

  defp user(index) do
    {:user, %User{index: index, parts: [], timestamp: nil, api_logs: [], metadata: %{}}}
  end

  defp tool(index) do
    {:tool, %Tool{index: index, parts: [], timestamp: nil, api_logs: []}}
  end

  defp assistant(index) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.Text{text: "ok"}],
       timestamp: nil,
       api_logs: []
     }}
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
