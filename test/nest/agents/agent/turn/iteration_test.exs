defmodule Nest.Agents.Agent.Turn.IterationTest do
  @moduledoc """
  `Iteration.tool_config_for_iteration/1` — the `{tools, tool_choice}`
  pair the turn hands the HTTP worker.

  This is the whole of the max-iterations contract on the request side:
  at/over the cap the call must be issued with `tools: nil,
  tool_choice: :none` so the model answers in text instead of asking for
  another tool round. It is a pure function of the turn state, so the
  contract is pinned here rather than inferred from the end of a
  multi-round acceptance turn (where a passing test cannot tell the
  final call from an ordinary one).
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatState.Live
  alias Nest.Agents.Agent.Turn.Iteration

  @tools [%{name: "context-check"}]

  test "tools are dropped only once the iteration counter passes the cap" do
    # Below the cap the turn's own tools and tool choice pass through.
    assert Iteration.tool_config_for_iteration(state(4, 5)) == {@tools, :auto}

    # Still at the cap: the last in-budget round keeps its tools.
    assert Iteration.tool_config_for_iteration(state(5, 5)) == {@tools, :auto}

    # Past the cap: this is the final call.
    assert Iteration.tool_config_for_iteration(state(6, 5)) == {nil, :none}
  end

  defp state(iteration, max_iterations) do
    %Nest.Agents.Agent{
      live: %Live{
        turn: %Live.Turn{
          iteration: iteration,
          max_iterations: max_iterations,
          ctx: %{tools: @tools, tool_choice: :auto}
        }
      }
    }
  end
end
