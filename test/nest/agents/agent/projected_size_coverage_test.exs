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
  names must cover every registered tool, and each clause must return something
  positive rather than a 0 that passes a membership check.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox.Mounts
  alias Nest.Tools.Groups

  defp call(id, name, arguments) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  defp ctx(tools, opts \\ []) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: Keyword.get(opts, :context_limit, 100_000),
      messages: Keyword.get(opts, :messages, []),
      mounts:
        Mounts.new(Keyword.get(opts, :workspace_path, nil), Keyword.get(opts, :tmp_path, nil)),
      agent_pid: self(),
      agent_name: "test",
      space_id: Keyword.get(opts, :space_id, nil)
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

    test "the history and status tools project a positive size" do
      # `projected?/1` is list membership; this exercises the clauses
      # themselves, so a projection that returned 0 (or fell to the catch-all
      # for a hallucinated name) cannot pass as covered.
      c = ctx([])

      for name <- ~w(agents-history agents-status) do
        assert ProjectedSize.project(call("c-#{name}", name, %{}), c) > 0,
               "#{name}'s projection is not positive"
      end

      # `agents-history` is unbounded by construction, so it projects at the
      # substitute minimum like the other response-bearing sub-agent tools.
      assert ProjectedSize.project(call("c", "agents-history", %{}), c) ==
               ProjectedSize.project(call("c", "agents-wait", %{}), c)
    end

    test "the pane tools project a positive size" do
      # Same reason as above: membership is not the clause. The two that read a
      # list project one representative report, so their projection must be
      # larger than the substitute minimum a tool with no shape projects at —
      # the minimum is not the contract, a realistic list is.
      c = ctx([])
      minimum = ProjectedSize.summary_baseline_size()

      for name <- ~w(decisions-ask decisions-obsolete todos-write decisions-list todos-list) do
        assert ProjectedSize.project(call("c-#{name}", name, %{}), c) > 0,
               "#{name}'s projection is not positive"
      end

      for name <- ~w(decisions-list todos-list) do
        assert ProjectedSize.project(call("c-#{name}", name, %{}), c) > minimum,
               "#{name} projects at the substitute minimum, not at a real list"
      end
    end
  end
end
