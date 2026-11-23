defmodule Nest.Agents.Agent.ToolLoopListAgentsTest do
  @moduledoc """
  `agents-list` reports every listed agent's **current** mode and its running
  shell-job count (#225).

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
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs

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

  test "keeps the listing inside the tool's 4000-character cap, with the longest mode", %{
    space_id: space_id
  } do
    # The longest mode name is the worst case for the column #193 added: the
    # entry is serialized whole, so a longer value is what could push a listing
    # past the cap. Taken from the catalog rather than written down, so a third
    # mode is measured too.
    longest = Enum.max_by(Nest.Modes.names(), &String.length/1)

    # A listing that fits: every entry is whole and the result is under the cap,
    # so the mode column costs what it costs and nothing is dropped.
    fits = "fits-#{System.unique_integer([:positive])}"
    {:ok, _row} = insert_row(space_id, fits, longest)

    content = list(space_id)
    assert String.length(content) < 4_000
    assert String.ends_with?(content, "}]")
    assert entry_for(content, fits) =~ ~s(mode: "#{longest}")

    # A listing that does not: the cap is hit exactly, and the head entry is
    # still whole — the truncation is the tail, which is what the cap is for.
    # This space has no human, so the listing is the whole result, and the
    # listing is sorted by name, so `first` is the entry at the head.
    first = "agent-with-a-long-name-1"
    for n <- 1..80, do: insert_row(space_id, "agent-with-a-long-name-#{n}", longest)

    content = list(space_id)
    assert String.length(content) == 4_000
    assert entry_for(content, first) =~ ~s(mode: "#{longest}")
  end

  # The running-job count is the space's, read once for the whole listing
  # (#225): the same number the sidebar's agent rows show. A foreground
  # `shell-cmd` call is a job while it runs (#174), so `register_owned` is the
  # real registration path — no OS process needed to have a running job.
  test "reports each agent's running shell-job count, and zero when none run", %{
    space_id: space_id
  } do
    busy = "busy-#{System.unique_integer([:positive])}"
    idle = "idle-#{System.unique_integer([:positive])}"
    {:ok, _row} = insert_row(space_id, busy, "act")
    {:ok, _row} = insert_row(space_id, idle, "act")

    key = {space_id, busy}
    root = Path.join(System.tmp_dir!(), "nest_list_jobs_#{System.unique_integer([:positive])}")
    scratch = Path.join(root, "scratch")
    File.mkdir_p!(scratch)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      if String.contains?(root, "nest_list_jobs_"), do: File.rm_rf(root)
    end)

    {:ok, job} =
      ShellJobs.register_owned(%{
        agent_key: key,
        command: "sleep 30",
        mounts: Mounts.new(nil, scratch, "none", space_id),
        os_pid: 1
      })

    content = list(space_id)
    assert entry_for(content, busy) =~ "running_jobs: 1"
    # An agent with no jobs is 0, not absent: the key is always there, so a
    # reader never has to guess what a missing count means.
    assert entry_for(content, idle) =~ "running_jobs: 0"

    # A finished job is not live: the count drops when the call ends, while
    # the job itself stays listed for `shell-wait`.
    :ok = ShellJobs.finish_owned(job.id, 0)
    assert entry_for(list(space_id), busy) =~ "running_jobs: 0"
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
