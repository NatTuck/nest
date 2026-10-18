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
                parts: [%Part.Text{text: "[nest notice]\nNotice."}],
                metadata: %{"context_threshold" => "p25"}
              }} = second
    end

    test "defers when the trailing assistant carries an unpaired tool_use" do
      assert :deferred ==
               NoticePairInjector.build_pair([assistant_tool_use(0)], spec(), :agent_user)
    end
  end

  describe ":user_agent direction" do
    test "trailing :user builds [assistant(bridge), user(notice), assistant(ack)]" do
      # The notice is a user row in every shape — the runtime's words are never
      # the agent's — so the alternation is repaired explicitly instead of fusing
      # the notice and its ack into one assistant row.
      tail = [user(0)]

      assert {:ok, [bridge, notice, ack]} =
               NoticePairInjector.build_pair(tail, spec(), :user_agent)

      # The bridge is the canonical `:live` alternation ack, not a new wording.
      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Okay, continuing from here."}]}} =
               bridge

      # The threshold metadata rides the notice row now: it used to ride the
      # fused assistant row, and `ContextReminder.announced_thresholds/1` reads
      # it off whichever row carries it.
      assert {:user,
              %User{
                parts: [%Part.Text{text: "[nest notice]\nNotice."}],
                metadata: %{"context_threshold" => "p25"}
              }} = notice

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}} = ack
      assert alternates?(tail ++ [bridge, notice, ack])
    end

    test "trailing :user with a budget spec defaults the ack" do
      spec = %{kind: :budget, attention: "Tool limit?", notice: "Last round."}

      assert {:ok, [_bridge, notice, ack]} =
               NoticePairInjector.build_pair([user(0)], spec, :user_agent)

      assert {:user, %User{parts: [%Part.Text{text: "[nest notice]\nLast round."}]}} = notice
      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Okay, noted."}]}} = ack
    end

    test "trailing :tool builds the same three rows, with the notice on a user row" do
      # Trailing `:tool` is wire-equivalent to `:user`, so it takes the same
      # bridge. The notice's *role* is the point of the shape: only a user row
      # can carry the runtime's own words without impersonating the agent.
      tail = [tool(0)]

      assert {:ok, [bridge, notice, ack]} =
               NoticePairInjector.build_pair(tail, spec(), :user_agent)

      assert {:assistant, _} = bridge
      assert {:user, %User{parts: [%Part.Text{text: "[nest notice]\nNotice."}]}} = notice
      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}} = ack
      assert alternates?(tail ++ [bridge, notice, ack])
    end

    test "trailing :assistant (no tool_use) builds [user(notice), assistant(ack)]" do
      assert {:ok,
              [
                {:user, %User{parts: [%Part.Text{text: "[nest notice]\nNotice."}]}},
                {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
              ] = rows} = NoticePairInjector.build_pair([assistant(0)], spec(), :user_agent)

      assert alternates?([assistant(0)] ++ rows)
    end

    test "defers when the trailing assistant carries an unpaired tool_use" do
      assert :deferred ==
               NoticePairInjector.build_pair([assistant_tool_use(0)], spec(), :user_agent)
    end
  end

  describe "notice_record/3" do
    test "opens with the bridge when the tail is user or tool, so the notice is a user row" do
      # A user-role notice on a wire-user tail is two consecutive user roles, so
      # the record opens with the alternation bridge: the notice and its
      # acknowledgement are two rows of their own, and neither is fused into an
      # assistant row that would read as the agent's words.
      for messages <- [[user(0)], [tool(0)]] do
        record = NoticePairInjector.notice_record(messages, "Notice.", "Ack.")

        assert [
                 {:assistant, %Assistant{parts: [%Part.Text{text: bridge}]}},
                 {:user, %User{parts: [%Part.Text{text: notice_row}]}},
                 {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
               ] = record

        assert bridge == "Okay, continuing from here."
        assert notice_row == "[nest notice]\nNotice."
        assert alternates?(messages ++ record), inspect(messages)
      end
    end

    test "lands the full pair when the tail is an assistant or nothing at all" do
      # An empty list has no tail to alternate with, so the pair is wire-legal
      # there too (`[user, assistant]` is the opening shape of any conversation).
      for messages <- [[assistant(0)], []] do
        record = NoticePairInjector.notice_record(messages, "Notice.", "Ack.")

        assert [
                 {:user, %User{parts: [%Part.Text{text: "[nest notice]\nNotice."}]}},
                 {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
               ] = record

        assert alternates?(messages ++ record), inspect(messages)
      end
    end

    test "resolves a deferred tail to the bridge shape the appender repairs without an ack" do
      # `build_pair/3` defers on an unpaired `tool_use` tail, because a caller
      # there has a next safe boundary to retry at. A record that must land now
      # does not, so it lands the bridge shape: the appender's terminal bridge
      # answers the unpaired ids before the first row arrives, and fabricates no
      # acknowledgement of its own (its incoming message is an assistant), so the
      # effective tail is `tool` and the three rows alternate.
      messages = [assistant_tool_use(0)]

      assert [
               {:assistant, _} = bridge,
               {:user, %User{parts: [%Part.Text{text: "[nest notice]\nNotice."}]}},
               {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}}
             ] = record = NoticePairInjector.notice_record(messages, "Notice.", "Ack.")

      # The repair the appender performs on the first row: one tool result and
      # *no* ack of its own — a second one would make the record close twice.
      assert [
               {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_0", is_error: true}]}} =
                 repaired
             ] = MessageList.pairing_bridge(messages, bridge)

      assert alternates?(messages ++ [repaired] ++ record)
    end
  end

  # --- helpers ---

  # `:tool` is wire-`user` (Anthropic sends tool results as user-role messages,
  # per `MessageList.last_wire_role/1`), so alternation is checked over the two
  # wire roles: two consecutive rows of the same one is what every provider
  # rejects.
  defp alternates?(messages) do
    messages
    |> Enum.map(fn
      {:tool, _} -> :user
      {role, _} -> role
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left != right end)
  end

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
