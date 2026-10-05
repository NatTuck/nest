defmodule Machine.TurnTest do
  @moduledoc false
  # NOTE: behavior contract carried by the tests + inline # comments.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine.Turn

  defp base(overrides) do
    Map.merge(
      %{
        compactor?: false,
        force_finalize: false,
        has_tool_calls: false,
        iteration: 0,
        max_iterations: 10,
        empty_assistant?: false,
        truncated?: false,
        silent?: false
      },
      overrides
    )
  end

  test "the compactor branch wins over everything" do
    # intentional: the compactor's turn has its own terminal
    # (compaction_done), so it is classified before any ordinary-turn
    # logic, even if the response happens to look like a tool call.
    assert Turn.classify_response(base(%{compactor?: true, has_tool_calls: true})) == :compaction
  end

  test "force_finalize wins over tool calls" do
    # intentional: force_finalize is the max-iterations second chance; the
    # reply is persisted and the turn ends, even if it contains tool calls.
    assert Turn.classify_response(base(%{force_finalize: true, has_tool_calls: true})) ==
             :force_finalize
  end

  test "tool calls past the cap overflow; within the cap they execute" do
    assert Turn.classify_response(
             base(%{has_tool_calls: true, iteration: 11, max_iterations: 10})
           ) ==
             :overflow_tool_calls

    assert Turn.classify_response(
             base(%{has_tool_calls: true, iteration: 10, max_iterations: 10})
           ) ==
             :normal_tool_calls
  end

  test "an empty assistant response is surfaced, not persisted" do
    assert Turn.classify_response(base(%{empty_assistant?: true})) == :empty_assistant
  end

  test "truncated is preferred over silent, and both over finalize" do
    assert Turn.classify_response(base(%{truncated?: true, silent?: true})) == :truncated
    assert Turn.classify_response(base(%{silent?: true})) == :silent
    assert Turn.classify_response(base(%{})) == :finalize
  end
end
