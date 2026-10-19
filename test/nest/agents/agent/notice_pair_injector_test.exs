defmodule Nest.Agents.Agent.NoticePairInjectorTest do
  @moduledoc """
  Tests for `NoticePairInjector.build_pair/3` and `notice_record/3` — the pure,
  wire-safe synthetic notice-pair builders the machine's user-message and
  LLM-response paths both use.

  The pair *shapes* are pinned by the tests that judge them by their real rule
  sets: `HeaderTest` walks every (direction, trailing role, notice kind)
  combination for which row carries the header, `WireInvariantTest` runs the
  composed lists through `Preflight.validate/1`, and `MessageAppendTagsTest`
  drives the stop record's deferred tail through the appender. What is left here
  is what only these two builders decide: the `:agent_user` deferral, the
  threshold metadata riding the notice row, the acknowledgement a spec does or
  does not supply, and the exact bridge the record opens with.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  describe ":agent_user direction" do
    test "defers when the trailing assistant carries an unpaired tool_use" do
      # `WireInvariantTest` pins the same guard for `:user_agent`; this is the
      # LLM-response direction's own copy of it.
      assert :deferred ==
               NoticePairInjector.build_pair([assistant_tool_use(0)], spec(), :agent_user)
    end
  end

  describe "the notice row's threshold metadata" do
    test "rides the notice row in both directions" do
      # The threshold used to ride a fused assistant row. It rides the notice row
      # in every shape now, and `ContextReminder.announced_thresholds/1` reads it
      # off whichever row carries it — so each direction has to keep passing it.
      for {direction, tail} <- [{:agent_user, []}, {:user_agent, [user(0)]}] do
        assert {:ok, rows} = NoticePairInjector.build_pair(tail, spec(), direction)

        assert {:user, %User{metadata: %{"context_threshold" => "p25"}}} =
                 Enum.find(rows, &match?({:user, _}, &1))
      end
    end
  end

  describe "the acknowledgement" do
    test "a spec's own ack lands on the closing assistant row" do
      assert {:ok, [{:user, _}, ack]} =
               NoticePairInjector.build_pair([assistant(0)], spec(), :user_agent)

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Ack."}]}} = ack
    end

    test "a spec with no ack falls back to its kind's default" do
      # `HeaderTest` pins the catch-all ("Okay."); this is the one kind-specific
      # default it does not reach.
      spec = %{kind: :budget, attention: "Tool limit?", notice: "Last round.", mode: "act"}

      assert {:ok, [_bridge, _notice, ack]} =
               NoticePairInjector.build_pair([user(0)], spec, :user_agent)

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Okay, noted."}]}} = ack
    end
  end

  describe "notice_record/3" do
    test "opens with the canonical bridge when the tail is user or tool" do
      # A user-role notice on a wire-user tail would be two consecutive user
      # roles, so the record opens with the alternation bridge. The wording is
      # pinned exactly because the record's `:deferred` branch builds its bridge
      # by hand (`MessageList.idle_bridge_ack(:live)`) instead of calling
      # `MessageList.pairing_bridge/2`, and the two must not drift apart.
      for messages <- [[user(0)], [tool(0)]] do
        assert [
                 {:assistant,
                  %Assistant{parts: [%Part.Text{text: "Okay, continuing from here."}]}},
                 {:user, _},
                 {:assistant, _}
               ] = NoticePairInjector.notice_record(messages, "Notice.", "Ack.", "act")
      end
    end
  end

  # --- helpers ---

  defp spec do
    %{
      kind: :context,
      attention: "Context?",
      notice: "Notice.",
      ack: "Ack.",
      threshold: :p25,
      mode: "act"
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
