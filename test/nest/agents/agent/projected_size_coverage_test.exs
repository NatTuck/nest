defmodule Nest.Agents.Agent.ProjectedSizeCoverageTest do
  @moduledoc """
  Every registered tool has an explicit result-size projection.

  Split out of `BatchSizerTest` (which owns the sizer's three phases) because it
  is a contract on `ProjectedSize`'s table rather than on the sizer's behaviour,
  and because that file is at credo's source-line cap.

  `ProjectedSize.project/2` has a catch-all that sizes a *hallucinated* tool's
  error string. A registered tool that falls to it would be sized as if it
  returned an error, so the preflight would under-count a real result — which is
  what these tests exist to make impossible: the list of explicitly projected
  names must cover every registered tool, and the response-bearing tools must
  project at the size their clauses claim.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox.Mounts
  alias Nest.Tools.Groups

  defp call(id, name, arguments) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  defp ctx do
    %{
      tools: [],
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: 100_000,
      messages: [],
      mounts: Mounts.new(nil, nil),
      agent_pid: self(),
      agent_name: "test",
      space_id: nil
    }
  end

  describe "ProjectedSize coverage" do
    test "every registered tool has an explicit projection" do
      registered =
        Groups.all()
        |> Groups.expand()
        |> Enum.reject(&(&1 == "context-compact"))

      missing = Enum.reject(registered, &ProjectedSize.projected?/1)

      assert missing == [],
             "registered tools with only the catch-all projection: #{inspect(missing)}"
    end

    test "the response-bearing tools project at the size their clauses claim" do
      # `projected?/1` is list membership; this exercises the clauses
      # themselves. Both assertions below fail if a clause is replaced by the
      # catch-all, which is the drift a membership list cannot see.
      c = ctx()
      minimum = ProjectedSize.summary_baseline_size()

      # `agents-history` is unbounded by construction, so it projects at the
      # substitute minimum like the other response-bearing sub-agent tools.
      assert ProjectedSize.project(call("c", "agents-history", %{}), c) ==
               ProjectedSize.project(call("c", "agents-wait", %{}), c)

      # The two pane tools that read a list project one representative report,
      # so their projection must be larger than the substitute minimum a tool
      # with no shape projects at — the minimum is not the contract, a
      # realistic list is.
      for name <- ~w(decisions-list todos-list) do
        assert ProjectedSize.project(call("c-#{name}", name, %{}), c) > minimum,
               "#{name} projects at the substitute minimum, not at a real list"
      end
    end
  end
end
