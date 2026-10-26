defmodule Nest.Sandbox.ShellJobsForegroundTest do
  @moduledoc """
  Issue #174: a foreground `shell-cmd` call is a shell job for as long as it runs.

  Split from `Nest.Sandbox.ShellJobsTest` for the file cap, and because the
  subject is one thing: a call that the manager does not own a process for, and
  what that call's record has to be — listed while it runs, finished when it
  ends, killable, and not a background job.

  Every test here drives a real command through `Nest.Tools.ShellCmd` (or the
  `shell-cmd` tool itself), because the registration is the tool path's: the file
  tools' and the sandbox helpers' commands go through the same module and must
  *not* register (`execute_raw/4`, `Nest.Sandbox.write/4`).
  """

  use ExUnit.Case, async: true

  import Eventually
  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup

  alias Nest.Sandbox.{Mounts, Paths}
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.Info
  alias Nest.Tools
  alias Nest.Tools.ShellCmd

  setup do
    # A real space id: the manager's job-list broadcast is keyed by
    # `{space_id, name}`, so a key whose first element is not an integer would
    # silently disable it. Unique, so a `scope: "space"` listing cannot pick up a
    # concurrent test's jobs.
    space_id = System.unique_integer([:positive])
    name = "foreground-#{System.unique_integer([:positive])}"
    key = {space_id, name}
    root = Path.join(System.tmp_dir!(), "nest_jobs_fg_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-#{space_id}", name])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      rm_tmp!(root, "nest_jobs_fg_")
    end)

    %{key: key, tmp: tmp, name: name, space_id: space_id, context: context(key)}
  end

  # A call that registers itself as a shell job, the way the `shell-cmd` tool
  # does. `agent_pid` is passed in rather than taken from `self()` because the
  # call runs in a `Task`: the agent it belongs to is the test process, and a
  # worker's own death must not drop the agent's jobs.
  defp run_foreground(command, tmp, key, agent_pid, opts \\ []) do
    ShellCmd.execute(
      command,
      Mounts.new(File.cwd!(), tmp),
      nil,
      Keyword.merge([register_job: true, agent_key: key, agent_pid: agent_pid], opts)
    )
  end

  defp context({space_id, name}), do: %{space_id: space_id, agent_name: name, caps: nil}

  # A command that runs until the test says so: `echo started`, then it waits for
  # a file the test writes. No sleep in the test, and the call cannot finish on
  # its own, so "while it runs" is a real window rather than a race.
  defp gated_command(tmp) do
    "echo started\n" <>
      "while [ ! -f #{Paths.sandbox_tmp_path(tmp)}/go ]; do sleep 0.01; done\n" <>
      "echo finished"
  end

  # Let the gated command finish: it is polling for this file, so the test itself
  # never sleeps.
  defp gate!(tmp), do: File.write!(Path.join(tmp, "go"), "")

  defp invoke(tool, args, context), do: tool.function.(args, context)

  test "a foreground call is listed while it runs and exited after, its output kept", %{
    key: {space_id, name} = key,
    tmp: tmp
  } do
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
    test_pid = self()

    task = Task.async(fn -> run_foreground(gated_command(tmp), tmp, key, test_pid) end)

    # The registration frame is the event that says the call is now a job; it is
    # broadcast before the registration call replies, so the command is running
    # when this arrives.
    assert_receive {:shell_jobs, %{jobs: [%{id: id, status: :running}]}}, 1_000

    assert [%{id: ^id, status: :running}] = ShellJobs.list(key)

    # The log is written as the output arrives, not at the end: that is what makes
    # a mid-run log read (and a killed job's) show anything.
    assert eventually(fn -> ShellJobs.output(key, id) == {:ok, "started\n"} end, timeout: 500)

    gate!(tmp)
    assert {:ok, "started\nfinished\n"} = Task.await(task, 1_000)

    # A call to the manager after the task returned: `finish_owned/2` is a call,
    # so the record is exited before the task's result is.
    assert [%{id: ^id, status: :exited, exit_code: 0, killed: false}] = ShellJobs.list(key)
    assert {:ok, "started\nfinished\n"} = ShellJobs.output(key, id)
  end

  # The `shell-cmd` tool is the only caller that sets `register_job`, so this is
  # the wiring's own test: a normal call through the tool leaves a *finished* job
  # behind, never a running one.
  test "the shell-cmd tool registers its call, and a normal call ends finished", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    tool = Tools.get_function("shell-cmd", Mounts.new(File.cwd!(), tmp))

    assert {:ok, "hello\n"} = invoke(tool, %{"command" => "echo hello"}, context)

    assert [%{id: id, status: :exited, exit_code: 0, command: "echo hello"}] =
             ShellJobs.list(key)

    assert {:ok, "hello\n"} = ShellJobs.output(key, id)
  end

  # The reported bug: a batch moved to the background (#36) kept running, but its
  # `shell-cmd` call was invisible — the agent's `shell-list` and the space's
  # listing showed only jobs started with `background: true`, so a long call in
  # flight looked like nothing at all.
  #
  # Backgrounding a batch changes nothing about the call itself (the machine only
  # stops waiting on its worker), so the test runs the call in a `Task`: what it
  # asserts is the state the agent then reads, and that the call's own result is
  # still the only report of it.
  test "a backgrounded batch's running call is listed by both listings (#174)", %{
    key: {space_id, name} = key,
    tmp: tmp,
    context: context
  } do
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
    test_pid = self()

    task = Task.async(fn -> run_foreground(gated_command(tmp), tmp, key, test_pid) end)
    assert_receive {:shell_jobs, %{jobs: [%{id: id, status: :running}]}}, 1_000

    list = Tools.get_function("shell-list", Mounts.new(nil, nil))

    assert {:ok, agent_text} = invoke(list, %{}, context)
    assert agent_text =~ "- #{id}: running"

    assert {:ok, space_text} = invoke(list, %{"scope" => "space"}, context)
    assert space_text =~ "- #{id} (owner: #{name}): running"

    gate!(tmp)
    assert {:ok, _output} = Task.await(task, 1_000)

    # The call's own result is the agent's report, so the manager must not also
    # deliver a `shell_job_exited` notice: that would be a second turn on a call
    # whose result already arrived. (`agent_pid` above is this process, so a
    # notice would land here — the refusal is not vacuous.)
    refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
  end

  test "shell-kill stops a running foreground call, and the call returns its result", %{
    key: {space_id, name} = key,
    tmp: tmp,
    context: context
  } do
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
    test_pid = self()

    task = Task.async(fn -> run_foreground("echo started; sleep 30", tmp, key, test_pid) end)
    assert_receive {:shell_jobs, %{jobs: [%{id: id, status: :running}]}}, 1_000

    # The capture spans the kill and the call's own return: the worker logs the
    # non-zero exit in between, and it is a permanent operator diagnostic
    # (`Nest.Tools.ShellCmd.Diagnostics`), asserted below so it does not escape
    # into the suite's output.
    log =
      capture_log(fn ->
        kill = Tools.get_function("shell-kill", Mounts.new(nil, nil))
        assert {:ok, text} = invoke(kill, %{"id" => id}, context)
        assert text =~ id

        # The manager does not own this process, so the kill reached the worker as
        # a `{:kill_job, id}` message: the call returns its own killed result
        # instead of running out its command or hanging.
        assert {:error, message} = Task.await(task, 1_000)
        assert message =~ "Exit code 137"
        assert message =~ "[Command killed]"
      end)

    assert log =~ "ShellCmd.execute: bwrap exited non-zero (exit_code=137)"

    assert [%{id: ^id, status: :exited, killed: true, exit_code: 137}] = ShellJobs.list(key)
  end

  # `caps.shell.background` is the *background* cap. A foreground call is not a
  # background job, so it must be neither refused by a full cap nor take a slot
  # in it — otherwise a single background job would make `shell-cmd` unusable.
  test "the background cap neither refuses nor counts a foreground call", %{
    key: key,
    tmp: tmp
  } do
    mounts = Mounts.new(File.cwd!(), tmp)

    assert {:ok, started} =
             ShellCmd.execute("sleep 30", mounts, nil,
               background: true,
               agent_key: key,
               grace_ms: 0
             )

    assert started =~ "Started background job"

    # The cap is really in force: a second background job is refused.
    assert {:error, refused} =
             ShellCmd.execute("sleep 30", mounts, nil,
               background: true,
               agent_key: key,
               grace_ms: 0
             )

    assert refused =~ "limit reached"

    # ... and a foreground call runs to completion anyway, listed next to the
    # still-running background job (running first, then finished).
    assert {:ok, "foreground\n"} = run_foreground("echo foreground", tmp, key, self())

    assert [
             %{status: :running, command: "sleep 30"},
             %{status: :exited, command: "echo foreground"}
           ] =
             ShellJobs.list(key)
  end

  # `file-write` runs its command through `ShellCmd.execute/4` too, and so does
  # `file-edit`; both are short internal steps, not jobs.
  test "a file-write registers no shell job", %{key: key, tmp: tmp, context: context} do
    # A job that already exists, so "nothing was registered" has a positive
    # observable: the list still holds exactly the jobs it held before.
    assert {:ok, _} =
             ShellCmd.execute("true", Mounts.new(File.cwd!(), tmp), nil,
               background: true,
               agent_key: key,
               grace_ms: 500
             )

    before_ids = Enum.map(ShellJobs.list(key), & &1.id)
    assert length(before_ids) == 1

    write = Tools.get_function("file-write", Mounts.new(File.cwd!(), tmp))
    sandbox_path = Path.join(Paths.sandbox_tmp_path(tmp), "written.txt")

    assert {:ok, _} = invoke(write, %{"path" => sandbox_path, "content" => "hi"}, context)
    # The write really happened, so the test is not passing on a no-op tool call.
    assert File.read!(Path.join(tmp, "written.txt")) == "hi"

    assert Enum.map(ShellJobs.list(key), & &1.id) == before_ids
  end

  # The registration is public API on a process-global GenServer, so it has to be
  # total: a call it cannot log is refused rather than raising (which would take
  # every agent's jobs down with it), and a finish for a job it does not track —
  # a second finish, or one after a kill's fallback ended it — changes nothing.
  test "registering a call with nowhere to log it is refused, and a finish is idempotent", %{
    key: key
  } do
    assert {:error, reason} =
             ShellJobs.register_owned(%{
               agent_key: key,
               command: "echo hi",
               mounts: Mounts.new(nil, nil),
               os_pid: 1
             })

    assert reason =~ "scratch"
    assert ShellJobs.list(key) == []

    assert :ok = ShellJobs.finish_owned("job-999", 0)
    assert ShellJobs.list(key) == []
  end

  # A long tail of finished jobs must not bury the live one: a listing is read to
  # find what is happening *now*.
  test "a running job sorts before a finished one, however new the finished one is" do
    key = {1, "order-agent"}
    base = ~U[2024-01-01 00:00:00Z]

    jobs = %{
      "job-1" => job("job-1", :running, base, key),
      "job-2" => job("job-2", {:exited, 0}, DateTime.add(base, 120, :second), key),
      "job-3" => job("job-3", :running, DateTime.add(base, 60, :second), key),
      "job-4" => job("job-4", {:exited, 1}, DateTime.add(base, 30, :second), key)
    }

    assert Info.list(jobs, fn _ -> true end) |> Enum.map(& &1.id) ==
             ["job-3", "job-1", "job-2", "job-4"]
  end

  defp exit_code({:exited, code}), do: code
  defp exit_code(:running), do: nil

  # The wire shape `Info.list/2` reads, with only the fields it uses.
  defp job(id, status, started_at, agent_key) do
    %{
      id: id,
      agent_key: agent_key,
      command: "cmd #{id}",
      status: status,
      exit_code: exit_code(status),
      killed: false,
      log_path: "/tmp/#{elem(agent_key, 1)}/shell-jobs/#{id}.log",
      started_at: started_at
    }
  end
end
