defmodule Nest.Tokens.BudgetPlannerTest do
  @moduledoc """
  Tests for `Nest.Tokens.BudgetPlanner`.

  Covers the full per-tool-call loop:
    * Fits as-is → keep
    * Truncates → head-truncate with note
    * Skips (per-call too big even truncated) → skip response
    * Cascades skip to all remaining when budget_for_this < min_skip_trigger
    * Tool default + LLM override on max_result_tokens
    * Order preservation
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.ToolCall
  alias Nest.Tokens.BudgetPlanner

  # A small executor that returns {result, default_max} for each
  # call. The default_max is the tool's "max_result_tokens" cap.
  defp make_executor(results) do
    fn %ToolCall{id: id} = _call ->
      case Map.fetch(results, id) do
        {:ok, value} -> {value, 8192}
        :error -> {"", 8192}
      end
    end
  end

  defp make_executor_with_max(results) do
    fn %ToolCall{id: id} = _call ->
      case Map.fetch(results, id) do
        {:ok, {value, max_tokens}} -> {value, max_tokens}
        :error -> {"", 8192}
      end
    end
  end

  describe "execute/4 — empty batch" do
    test "returns empty list" do
      assert BudgetPlanner.execute([], make_executor(%{}), 1000) == []
    end
  end

  describe "execute/4 — fits as-is" do
    test "keeps small results unchanged" do
      results = %{
        "1" => "small",
        "2" => "tiny"
      }

      out =
        BudgetPlanner.execute(
          [
            %ToolCall{id: "1", name: "foo", arguments: %{}},
            %ToolCall{id: "2", name: "bar", arguments: %{}}
          ],
          make_executor(results),
          10_000
        )

      assert length(out) == 2
      assert Enum.at(out, 0) == {%ToolCall{id: "1", name: "foo", arguments: %{}}, "small"}
      assert Enum.at(out, 1) == {%ToolCall{id: "2", name: "bar", arguments: %{}}, "tiny"}
    end
  end

  describe "execute/4 — truncates" do
    test "head-truncates a single too-big result with a note" do
      big = String.duplicate("a", 5000)
      results = %{"1" => big}

      [{call, result}] =
        BudgetPlanner.execute(
          [%ToolCall{id: "1", name: "foo", arguments: %{}}],
          make_executor(results),
          1_000
        )

      assert call.id == "1"
      # Result should be truncated, not the full 5000 chars
      assert String.length(result) < 5000
      # And the note should be present
      assert result =~ "[truncated:"
    end
  end

  describe "execute/4 — skips" do
    test "skips when result is too big even for truncation" do
      # Tiny budget, big result → can't truncate to a useful size
      big = String.duplicate("a", 100_000)
      results = %{"1" => big}

      [{_call, result}] =
        BudgetPlanner.execute(
          [%ToolCall{id: "1", name: "foo", arguments: %{}}],
          make_executor(results),
          100
        )

      assert result =~ "[skipped:"
      assert result =~ "foo"
    end
  end

  describe "execute/4 — cascade skip" do
    test "cascades skip to all remaining when budget exhausted" do
      results = %{
        "1" => "small",
        "2" => "small",
        "3" => "small"
      }

      # Budget too small to fit any call after the first
      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{}},
        %ToolCall{id: "2", name: "bar", arguments: %{}},
        %ToolCall{id: "3", name: "baz", arguments: %{}}
      ]

      out = BudgetPlanner.execute(calls, make_executor(results), 250)
      # The first call may fit, but the rest should cascade
      # because future_skip_cost makes budget_for_this too small
      # to be useful.
      assert length(out) == 3
      # At least one of the later calls should be skipped
      assert Enum.any?(out, fn {_, r} -> String.contains?(r, "[skipped:") end)
    end
  end

  describe "execute/4 — max_result_tokens override" do
    test "LLM override is respected (smaller than default)" do
      # Default cap is 8192, but LLM asks for 500 — a value above
      # min_truncatable (256) so it triggers truncation, not skip.
      big = String.duplicate("a", 50_000)
      results = %{"1" => big}

      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{"max_result_tokens" => 500}}
      ]

      [{_call, result}] =
        BudgetPlanner.execute(calls, make_executor(results), 10_000)

      # Should be truncated (capped at ~500 tokens, not 8192)
      assert String.length(result) < 5000
      assert result =~ "[truncated:"
    end

    test "LLM override below min_truncatable triggers skip" do
      # The LLM requested 100 tokens which is below the 256-token
      # minimum useful threshold — the call is skipped instead.
      big = String.duplicate("a", 50_000)
      results = %{"1" => big}

      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{"max_result_tokens" => 100}}
      ]

      [{_call, result}] =
        BudgetPlanner.execute(calls, make_executor(results), 10_000)

      assert result =~ "[skipped:"
    end

    test "executor's default max_result_tokens is used when LLM doesn't override" do
      # Executor returns default_max = 100; LLM doesn't override.
      # Result is 5000 chars, but tool cap is only 100 tokens.
      results = %{"1" => {String.duplicate("a", 5000), 100}}

      [{_call, result}] =
        BudgetPlanner.execute(
          [%ToolCall{id: "1", name: "foo", arguments: %{}}],
          make_executor_with_max(results),
          10_000
        )

      # Should be truncated to ~100 tokens
      assert String.length(result) < 1000
    end
  end

  describe "execute/4 — order preservation" do
    test "results are returned in the same order as calls" do
      results = %{"1" => "a", "2" => "b", "3" => "c"}

      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{}},
        %ToolCall{id: "2", name: "bar", arguments: %{}},
        %ToolCall{id: "3", name: "baz", arguments: %{}}
      ]

      out = BudgetPlanner.execute(calls, make_executor(results), 10_000)

      assert Enum.map(out, fn {c, _} -> c.id end) == ["1", "2", "3"]
    end
  end

  describe "execute/4 — multiple tool calls with mixed outcomes" do
    test "first fits, second truncates, third skips" do
      small = "small enough"
      medium = String.duplicate("m", 3000)
      huge = String.duplicate("h", 50_000)

      results = %{"1" => small, "2" => medium, "3" => huge}

      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{}},
        %ToolCall{id: "2", name: "bar", arguments: %{}},
        %ToolCall{id: "3", name: "baz", arguments: %{}}
      ]

      [first, second, third] =
        BudgetPlanner.execute(
          calls,
          make_executor_with_max(Map.new(results, fn {k, v} -> {k, {v, 8192}} end)),
          2_000
        )

      # First fits
      assert elem(first, 1) =~ "small enough"
      refute elem(first, 1) =~ "[truncated:"

      # Second is truncated
      assert elem(second, 1) =~ "[truncated:"

      # Third is skipped (budget exhausted by first two)
      assert elem(third, 1) =~ "[skipped:"
    end
  end

  describe "execute/4 — tool_name extracted for skip messages" do
    test "skip response includes the tool name" do
      calls = [%ToolCall{id: "1", name: "shell_cmd", arguments: %{}}]
      huge = String.duplicate("x", 100_000)
      results = %{"1" => huge}

      [{_call, result}] = BudgetPlanner.execute(calls, make_executor(results), 50)
      assert result =~ "shell_cmd"
    end

    test "uses 'unknown' when name is missing" do
      # Map with no name
      calls = [%{id: "1"}]
      results = %{"1" => String.duplicate("x", 100_000)}

      [{_call, result}] = BudgetPlanner.execute(calls, make_executor(results), 50)
      assert result =~ "unknown"
    end
  end
end
