defmodule Nest.Agents.Agent.ToolLoopListAgentsTest do
  @moduledoc """
  `agents-list` reports every listed agent's **current** mode.

  A mode is per-agent runtime state, not a property of the space: a running
  agent's `state.live.mode` can be ahead of its row (a turn moves it, and
  `Turn.keep_mode/2` writes the row at the settle), so the listing reads the
  live value for a running agent. A persisted-only row has no live mode to
  disagree with, and its row's mode is what it starts in.

  Dispatch-level (`ToolLoop.execute/3`), like `ToolLoopHumanAddressTest`: the
  tool's own read is what is under test, so no chat turn and no LLM are needed.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Persistence

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id}
  end

  test "reports a running agent's live mode and a stopped row's", %{space_id: space_id} do
    plan_name = start_agent(space_id, mode: "plan")
    act_name = start_agent(space_id, mode: "act")
    stopped_name = "stopped-#{System.unique_integer([:positive])}"

    {:ok, _row} = insert_row(space_id, stopped_name, "plan")

    content = list(space_id)

    # A running agent: its mode is in the entry, and it is the agent's own (the
    # two agents differ, so this is not a constant).
    assert entry_for(content, plan_name) =~ ~s(mode: "plan")
    assert entry_for(content, act_name) =~ ~s(mode: "act")

    # A persisted-only row has no live mode; its row's is the one it starts in.
    assert entry_for(content, stopped_name) =~ ~s(mode: "plan")
  end

  test "reports the live mode, not the row, when the two disagree", %{space_id: space_id} do
    name = start_agent(space_id, mode: "act")

    # The row is what a restart and a later spawn read; the running process is
    # still in `act`. This is the shape `live` and the row have mid-turn, before
    # `Turn.keep_mode/2` writes the row at the settle — and the row can be left
    # saying something the agent never ran under.
    assert :ok = Persistence.update_agent_mode(space_id, name, "plan")
    assert {:ok, %{mode: "plan"}} = Persistence.fetch_agent(space_id, name)

    assert entry_for(list(space_id), name) =~ ~s(mode: "act")
  end

  test "keeps the listing inside the tool's 4000-character cap", %{space_id: space_id} do
    for n <- 1..80, do: insert_row(space_id, "agent-with-a-long-name-#{n}", "act")

    content = list(space_id)

    # The cap is the tool's own (`@list_agents_max_chars`). This space has no
    # human, so the listing is the whole result and the cap is exactly hit —
    # which is what makes the assertion more than a tautology: a listing under
    # the cap would not reach 4000.
    assert String.length(content) == 4_000
    assert content =~ ~s(mode: "act")
  end

  # ---- helpers ----

  defp list(space_id) do
    [%ToolResult{content: content}] =
      ToolLoop.execute(ctx(space_id), nil, [
        %ToolCall{id: "call-1", name: "agents-list", arguments: %{}}
      ])

    content
  end

  # The tool's read is space-scoped and needs nothing else off the worker's
  # context (`run_list_agents/2` reads `ctx.space_id` only).
  defp ctx(space_id) do
    %{
      space_id: space_id,
      agent_name: "lister",
      agent_pid: self(),
      context_limit: 100_000,
      messages: [],
      tools: [],
      caps: %{},
      mode: "act"
    }
  end

  # `AgentTestHelpers.start_agent/1` does not pass a mode through (it is a
  # `create_agent/3` option), so the agents here are created directly.
  defp start_agent(space_id, opts) do
    name = "agent-#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        [name: name, vocation_id: AgentTestHelpers.vocation_id_for_test()] ++ opts
      )

    AgentTestHelpers.ensure_cleanup(name)
    name
  end

  defp insert_row(space_id, name, mode) do
    Persistence.insert_agent(%{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: AgentTestHelpers.vocation_id_for_test(),
      mode: mode
    })
  end

  # The result is `inspect/1` output of the listing, so an entry is one
  # `%{...}` map inside that string. `[^}]` keeps the match inside a single
  # entry regardless of the key order `inspect/1` chooses.
  defp entry_for(content, name) do
    [entry] = Regex.run(~r/%\{[^}]*name: "#{name}"[^}]*\}/, content)
    entry
  end
end
