defmodule Nest.Agents.Agent.Turn.NoticeInjectorTest do
  @moduledoc """
  Tests for the Case 2 notice-injection priority logic.

  `collect_case2_specs/2` gathers notice specs from all trigger sources
  (budget reminder, context-usage threshold) and returns the list to
  inject. The driver runs in the Agent process, so these read the Agent
  state directly (no GenServer round-trips).
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Turn.NoticeInjector
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  describe "collect_case2_specs/2 priority" do
    test "returns empty list when neither budget nor context fires" do
      state = build_state(pending_notice: nil, context_limit: 0)
      assert NoticeInjector.collect_case2_specs(%{}, state) == []
    end

    test "returns [budget] when only budget fires (context short-circuits)" do
      state =
        build_state(
          pending_notice: "2 tool call rounds remaining. Plan your remaining tool use carefully.",
          context_limit: 0
        )

      assert [budget] = NoticeInjector.collect_case2_specs(%{}, state)
      assert budget.kind == :budget
      assert budget.attention == "Tool limit?"
      assert budget.notice =~ "2 tool call rounds remaining"
    end
  end

  describe "collect_case2_specs/2 ordering (back-to-back)" do
    test "the order in the returned list is the injection order" do
      state = build_state(pending_notice: "Budget notice.", context_limit: 0)

      assert [only] = NoticeInjector.collect_case2_specs(%{}, state)
      assert only.kind == :budget
    end
  end

  describe "collect_case2_specs/2 tool-call projection" do
    test "uses the canonical BatchSizer content size, without adding the reserve again" do
      # `context_limit: 100_000` -> reserve 20_000, working budget 80_000.
      # An assistant anchor of 32_000 is 40% of the working budget, so a
      # tool response should cross only :p25. The pre-fix formula added
      # the reserve to the numerator ((32_000 + 20_000) / 80_000 = 65%)
      # and fired :p50.
      messages = [
        {:assistant,
         %Assistant{
           index: 1,
           parts: [%Part.Text{text: "x"}],
           usage: %{input_tokens: 32_000, output_tokens: 0}
         }}
      ]

      state =
        build_state(context_limit: 100_000, tools: [], messages: messages)

      response = %RunResponse{
        tool_calls: [%ToolCall{id: "c1", name: "shell-cmd", arguments: %{}}]
      }

      assert [spec] = NoticeInjector.collect_case2_specs(response, state)
      assert spec.kind == :context
      assert spec.threshold == :p25
      refute spec.notice =~ "50%"
    end
  end

  # `context_limit: 0` short-circuits the context spec computation, so the
  # budget-only paths exercise no projection math.
  defp build_state(opts) do
    messages = Keyword.get(opts, :messages, [])

    %Agent{
      chat_state: %Agent.ChatState{messages: messages},
      live: %Agent.ChatState.Live{
        crossed_thresholds: MapSet.new(),
        turn: %Agent.ChatState.Live.Turn{
          pending_notice: Keyword.get(opts, :pending_notice),
          ctx: %{
            agent_pid: self(),
            context_limit: Keyword.get(opts, :context_limit, 0),
            tools: Keyword.get(opts, :tools, []),
            tool_choice: :auto,
            messages: messages
          }
        }
      }
    }
  end
end
