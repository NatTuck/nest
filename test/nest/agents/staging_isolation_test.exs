defmodule Nest.Agents.StagingIsolationTest do
  @moduledoc """
  A live agent's staged command transcript is isolated from a sibling's
  teardown.

  Staging is per-agent (`Nest.Sandbox.Paths.stage_dir/1` puts the transcript in
  the agent's *own* scratch, `<scratch>/.cmds`), so the only things that can
  remove a live script are the staging call itself (after exec) and the owning
  agent's teardown — never a sibling's. This module holds a real command open
  in agent A, tears down sibling agent B in the same space, and asserts A's
  command still exits cleanly. The path-level and reclaim regressions live in
  `Nest.Sandbox.PathsTest` and `Nest.Agents.TmpSweeperTest`; this is the
  end-to-end guard that a sibling's full teardown (terminate + shell-jobs drop)
  cannot reach across into A's staging.

  `async: true`: a fresh space and unique agent names, and the only shared
  state touched is this test's own space directory.
  """
  use Nest.DataCase, async: true

  import Eventually

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Sandbox.{Mounts, Paths, ShellJobs}
  alias Nest.Tools.ShellCmd

  test "a sibling's teardown does not remove a live agent's staged script" do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    vid = AgentTestHelpers.vocation_id_for_test()
    unique = System.unique_integer([:positive])
    a_name = "staging-a-#{unique}"
    b_name = "staging-b-#{unique}"

    {:ok, ^a_name} = Agents.create_agent(space_id, model, name: a_name, vocation_id: vid)
    {:ok, ^b_name} = Agents.create_agent(space_id, model, name: b_name, vocation_id: vid)
    AgentTestHelpers.ensure_cleanup(a_name)
    AgentTestHelpers.ensure_cleanup(b_name)

    {:ok, a_pid} = Supervisor.get_agent(space_id, a_name)
    {:ok, b_pid} = Supervisor.get_agent(space_id, b_name)

    # allowlist: snapshot — the agent's own mounts and resolved caps, which the
    # command runs through; no accessor exposes them and there is no event for
    # "the agent started with these".
    state = :sys.get_state(a_pid, 1_000)
    mounts = Mounts.from_agent(state)
    caps = Agent.resolve_caps(state)
    scratch = Mounts.scratch(mounts)
    key = {space_id, a_name}

    # The command writes a marker (the barrier: bash has opened the script and
    # run its first line), then blocks reading a fifo until the test releases
    # it. Both live in A's own scratch, reached inside at /tmp/<a_name>.
    marker = Path.join(scratch, "started.marker")
    fifo = Path.join(scratch, "gate.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    sb_dir = Paths.sandbox_tmp_path(scratch)

    command = """
    printf started > '#{Path.join(sb_dir, "started.marker")}'
    cat '#{Path.join(sb_dir, "gate.fifo")}'
    echo done
    """

    # A real foreground call, registered as a shell job owned by A, so the
    # manager tracks it exactly as a tool call would.
    task =
      Task.async(fn ->
        ShellCmd.execute(command, mounts, caps,
          register_job: true,
          agent_key: key,
          agent_pid: a_pid
        )
      end)

    # Barrier: the marker is an event only a command that opened its script
    # produces. A script deleted before bash read it exits 127 and never writes
    # it, so this cannot pass for the bug.
    assert eventually(fn -> File.exists?(marker) end, timeout: 500)
    assert [%{status: :running}] = ShellJobs.list(key)

    # Tear down the sibling: terminate/2 removes B's scratch and the shell-jobs
    # manager drops B's jobs. Neither may reach A's staging.
    ref = Process.monitor(b_pid)
    :ok = Supervisor.stop_agent(space_id, b_name)
    assert_receive {:DOWN, ^ref, :process, ^b_pid, _reason}, 500

    # A's live transcript is still on disk, inside A's own scratch, and its
    # command is still running — the sibling's teardown reached neither.
    stage = Paths.stage_dir(scratch)
    assert Path.dirname(stage) == scratch
    assert [_script] = Path.wildcard(Path.join(stage, "nest-cmd-*.sh"))
    assert [%{status: :running}] = ShellJobs.list(key)

    # Release the blocked command. `cat` holds the fifo open for read, so this
    # open-for-write rendezvous completes deterministically (no clock).
    {:ok, fd} = :file.open(fifo, [:write])
    :ok = :file.write(fd, "released\n")
    :ok = :file.close(fd)

    # {:ok, _} is exit 0 (`Result.from_exit/4` answers {:error, "Exit code N"}
    # for any non-zero code), so a 127 from a missing script fails here.
    assert {:ok, output} = Task.await(task, 500)
    assert output =~ "released"
    assert output =~ "done"
  end
end
