defmodule Nest.Agents.Agent.SubAgentResultsTest do
  @moduledoc """
  Unit tests for `Nest.Agents.Agent.SubAgentResults.child_message/2` — the
  one place a child's outcome becomes inbox text.

  A completion is the child's own words (`kind: :agent`, so the inbox labels
  it `[Message from agent "X"]`). Everything else is the *runtime* speaking
  (`kind: :runtime`, rendered bare), because the child did not say it: a child
  that finished its turn without text, failed, or was stopped before it
  answered.
  """

  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.ResultPolicy
  alias Nest.Agents.Agent.SubAgentResults
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.Estimator

  test "a completion is the child's words; a child that did not answer is the runtime's" do
    for {result, content, kind} <- [
          {{:ok, "the answer"}, "the answer", :agent},
          {{:ok, ""}, "Child agent kid finished its turn without producing any text.", :runtime},
          {{:failed, :boom}, "Child agent kid failed before it answered: :boom", :runtime},
          {{:terminated, :shutdown}, "Child agent kid was stopped before it answered: :shutdown",
           :runtime}
        ] do
      assert SubAgentResults.child_message("kid", result) == {content, kind}
    end
  end

  describe "bound/3" do
    # The sub-agent tools bypass `BatchSizer`, so this is where their text meets
    # the same inline budget. The one caller is `agents-history`, whose
    # `on_over/1` is `:file` — hence no refusal arm in `bound/3`.
    @big String.duplicate("hello world ", 4_000)

    test "a result under the budget comes back whole, and one over it is filed" do
      dir =
        Path.join(System.tmp_dir!(), "sub-agent-results-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "sub-agent-results-") end)

      ctx = %{context_limit: 100, mounts: Mounts.new(nil, dir)}
      tc = %ToolCall{id: "c1", name: "agents-history", arguments: %{}}

      assert SubAgentResults.bound("short", tc, ctx) == "short"

      pointer = SubAgentResults.bound(@big, tc, ctx)
      assert pointer =~ "Output of agents-history"
      assert pointer =~ "saved to"

      # A pointer to the whole text, not a cut of it: the file holds every byte.
      [file] = Path.wildcard(Path.join(dir, "agents-*.txt"))
      assert File.read!(file) == @big
    end

    test "a result that cannot be filed says so and names its size" do
      # No mounts, so `Overflow.write/5` cannot write. The model is told the
      # content is unavailable — never an inline copy over the budget, and never
      # a silent drop.
      ctx = %{context_limit: 100, mounts: nil}
      tc = %ToolCall{id: "c1", name: "agents-history", arguments: %{}}

      size = Estimator.estimate(@big)
      failure = SubAgentResults.bound(@big, tc, ctx)

      assert failure == ResultPolicy.offload_failure(size)
      assert failure =~ "could not be written"
      assert failure =~ "#{size} tokens"
    end

    test "a context with no window bounds nothing" do
      # The fallback clause: no positive `context_limit` means there is no budget
      # to bound against, so the result is returned as it is.
      tc = %ToolCall{id: "c1", name: "agents-history", arguments: %{}}

      assert SubAgentResults.bound(@big, tc, %{}) == @big
      assert SubAgentResults.bound(@big, tc, %{context_limit: 0}) == @big
    end
  end
end
