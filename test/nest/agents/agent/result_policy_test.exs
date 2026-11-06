defmodule Nest.Agents.Agent.ResultPolicyTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.ResultPolicy`, the one place a result's inline
  size is decided.

  Pins the formula (`min(requested, budget)`, with no share of the window), the
  two sources of `requested` (the model's ask, else the tool's default), the
  `:file` / `:refuse` split, and the rule that a substitute must not be larger
  than the content it replaces.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.ResultPolicy
  alias Nest.Messages.ToolCall

  defp call(name, args \\ %{}), do: %ToolCall{id: "c1", name: name, arguments: args}

  describe "default_limit/1 and requested/1" do
    test "a tool that asks for nothing gets its default, and file-read's is larger" do
      # 8k is the floor for every tool; `file-read` is the one exception,
      # because its over-limit path refuses rather than substitutes and a
      # refusal costs a round trip.
      assert ResultPolicy.default_limit("shell-cmd") == 8_000
      assert ResultPolicy.default_limit("file-read") == 32_000
      assert ResultPolicy.requested(call("shell-cmd")) == 8_000
      assert ResultPolicy.requested(call("file-read", %{"path" => "a.txt"})) == 32_000
    end

    test "the model's ask replaces the default, in either direction" do
      assert ResultPolicy.requested(call("shell-cmd", %{"max_result_tokens" => 500})) == 500

      # Above the default is allowed: the default is what the tool wants in
      # context, not a ceiling on what the model may ask for.
      assert ResultPolicy.requested(call("shell-cmd", %{"max_result_tokens" => 40_000})) ==
               40_000
    end

    test "a malformed ask falls back to the default" do
      for bad <- [0, -5, "lots", nil, 1.5] do
        assert ResultPolicy.requested(call("shell-cmd", %{"max_result_tokens" => bad})) == 8_000
      end
    end
  end

  describe "limit/2" do
    test "is min(requested, budget)" do
      # Requested below the budget: the request wins.
      assert ResultPolicy.limit(call("shell-cmd", %{"max_result_tokens" => 2_000}), 50_000) ==
               2_000

      # Requested above the budget: the budget wins, so no result can be
      # inlined past what is actually left.
      assert ResultPolicy.limit(call("shell-cmd", %{"max_result_tokens" => 40_000}), 5_000) ==
               5_000

      # No request: the tool's default, still capped by the budget.
      assert ResultPolicy.limit(call("shell-cmd"), 5_000) == 5_000
      assert ResultPolicy.limit(call("shell-cmd"), 50_000) == 8_000
    end
  end

  describe "window/1" do
    test "answers a live, spent, or absent window" do
      # 100_000 leaves an 80_000-token content budget (the reserve is 20_000),
      # and a context carrying no `:messages` still has one.
      assert ResultPolicy.window(%{context_limit: 100_000}) == {:ok, 80_000}

      # 100 cannot hold the 8_192-token reserve, so the window is spent: a
      # legal zero, reported as `:none` rather than `{:ok, 0}`.
      assert ResultPolicy.window(%{context_limit: 100}) == :none

      # No positive limit at all.
      assert ResultPolicy.window(%{context_limit: nil}) == :none
    end
  end

  describe "admit/3" do
    test "keeps what fits, files what does not, and refuses when the policy says so" do
      big = String.duplicate("word ", 5_000)

      # Under the limit: inline, whatever the policy.
      assert {:inline, _size} = ResultPolicy.admit("short", 100, :file)

      # Over it: the policy decides, and the decision is the same content and
      # limit — only `on_over` differs.
      assert {:file, _size} = ResultPolicy.admit(big, 100, :file)
      assert {:refuse, _size} = ResultPolicy.admit(big, 100, :refuse)
    end

    test "keeps content no larger than the substitute that would replace it" do
      # Filing is only worth it when it makes the request smaller. A short
      # diagnostic over a spent budget stays readable inline — which is
      # exactly when the model needs it.
      small = "Batch refused: projected message list is over the limit."

      assert {decision, size} = ResultPolicy.admit(small, 0, :file)
      assert decision == :inline
      assert size <= Overflow.substitute_size()
    end
  end

  describe "on_over/1" do
    test "only file-read refuses, and refusal/3 is that refusal's wording" do
      assert ResultPolicy.on_over("file-read") == :refuse
      assert ResultPolicy.on_over("shell-cmd") == :file
      assert ResultPolicy.on_over("agents-history") == :file

      # `file-read` is the one refusal, so this is the one sentence a refusal
      # says: the size, and the knob that would have let the read through.
      assert ResultPolicy.refusal(33_000, 32_000, "file-read") ==
               "File is 33000 tokens which exceeds your requested limit of 32000."
    end
  end

  test "offload_failure/1 says the content is gone, and that re-running is the way back" do
    # Reached when the scratch write fails: there is no pointer to give, so the
    # model is told the content is unavailable — not that it was inlined (it was
    # not) and not that it is on disk (it is not). It names the size so the model
    # can tell how far over the cap it was.
    assert ResultPolicy.offload_failure(9_000) ==
             "Result of ~9000 tokens could not be included inline and could not be written " <>
               "to a scratch file. The content is unavailable; re-run the call if you still " <>
               "need it."
  end

  test "label/1 names the tool, not the call it was made with" do
    # The arguments are one part earlier, in the `tool_use` the label follows, so
    # a label that spelled them (`Output of shell-wait job-7`) repeated the
    # transcript and grew with whatever the argument quoted. This names which
    # tool produced the output and stops there.
    assert ResultPolicy.label("shell-wait") == "Output of shell-wait"
    assert ResultPolicy.label("file-read") == "Output of file-read"
  end
end
