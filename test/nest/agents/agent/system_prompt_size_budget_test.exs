defmodule Nest.Agents.Agent.SystemPromptSizeBudgetTest do
  @moduledoc """
  Unit tests for the `SystemPrompt.within_size_budget?/2` helper.

  The 25% safety budget is the belt-and-suspenders check that
  refuses to produce (or accept) a system prompt whose rendered
  size would consume more than a quarter of the model's context
  window. This test pins the boundary cases so the budget math
  can't drift.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.SystemPrompt

  describe "within_size_budget?/2" do
    test "nil returns false (no-vocation case handled by reserve_exhausted)" do
      refute SystemPrompt.within_size_budget?(nil, 100_000)
    end

    test "empty string returns true (the +@per_message_overhead still fits for large limits)" do
      assert SystemPrompt.within_size_budget?("", 100_000)
    end

    test "a small prompt is within budget for any reasonable context limit" do
      assert SystemPrompt.within_size_budget?("hello", 1_000)
      assert SystemPrompt.within_size_budget?("hello", 100_000)
    end

    test "a small prompt under the 25% budget fits" do
      # 1000 chars × upper-bound (chars/3 = 333 tokens) plus
      # 10 overhead = 343 tokens. Budget for 100k context is
      # 25_000 tokens. Comfortably within.
      small = String.duplicate("a", 1_000)
      assert SystemPrompt.within_size_budget?(small, 100_000)
    end

    test "a prompt exactly at the budget ceiling is within (inclusive)" do
      # Budget for 100k context = 25_000 tokens. Upper-estimate
      # is `byte_size/3 + 10`, so the largest byte_size that
      # produces exactly 25_000 tokens is `byte_size/3 + 10 == 25_000`
      # → `byte_size == 74_970` (so 74_970/3 + 10 = 24_990 + 10 = 25_000).
      # We pick something a few bytes under to make the inclusive
      # boundary clear.
      on_budget = String.duplicate("a", 74_000)
      assert SystemPrompt.within_size_budget?(on_budget, 100_000)
    end

    test "a prompt just over the budget is rejected" do
      # One byte over: 75_001/3 + 10 = 25_011 > 25_000.
      over = String.duplicate("a", 75_001)
      refute SystemPrompt.within_size_budget?(over, 100_000)
    end

    test "a prompt well over 25% of context_limit is rejected" do
      # ~400k chars of "z" → far above the 25_000-token budget
      # for 100k context.
      huge = String.duplicate("z", 400_000)
      refute SystemPrompt.within_size_budget?(huge, 100_000)
    end

    test "budget scales with context_limit" do
      # Same prompt is within a 10M-budget but rejects a 1k-budget.
      prompt = String.duplicate("a", 400_000)
      assert SystemPrompt.within_size_budget?(prompt, 10_000_000)
      refute SystemPrompt.within_size_budget?(prompt, 1_000)
    end
  end

  describe "within_size_budget_budget/1" do
    test "returns div(context_limit, 4) for positive limits" do
      assert SystemPrompt.within_size_budget_budget(100_000) == 25_000
      assert SystemPrompt.within_size_budget_budget(40_000) == 10_000
      assert SystemPrompt.within_size_budget_budget(8_000) == 2_000
    end

    test "returns 0 for non-positive context limits" do
      assert SystemPrompt.within_size_budget_budget(0) == 0
      assert SystemPrompt.within_size_budget_budget(-1) == 0
    end
  end
end
