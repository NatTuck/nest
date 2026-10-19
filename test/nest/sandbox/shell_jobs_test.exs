defmodule Nest.Sandbox.ShellJobsTest do
  use ExUnit.Case, async: true

  import Eventually
  import Nest.Test.TmpCleanup

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.{Mounts, Paths}
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.JobLog
  alias Nest.Tools.{ShellCmd, ShellEscape}

  setup do
    # A real space id: the manager's job-list broadcast is keyed by
    # `{space_id, name}`, so a key whose first element is not an integer would
    # silently disable it.
    key = {1, "agent-#{System.unique_integer([:positive])}"}
    root = Path.join(System.tmp_dir!(), "nest_jobs_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-1", elem(key, 1)])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      if String.contains?(root, "nest_jobs_"), do: File.rm_rf(root)
    end)

    %{key: key, tmp: tmp}
  end

  defp start_background(command, tmp, key, opts \\ []) do
    opts = Keyword.merge([background: true, agent_key: key, grace_ms: 0], opts)
    ShellCmd.execute(command, Mounts.new(File.cwd!(), tmp), nil, opts)
  end

  # Start a job that stays running past the grace window and return its id.
  defp start_running!(command, tmp, key) do
    assert {:ok, message} = start_background(command, tmp, key)
    assert message =~ "Started background job"

    assert [%{id: id}] = ShellJobs.list(key)
    id
  end

  # The manager owns the waiter list, so read it directly instead of
  # racing an OS kill against a fixed receive timeout.
  defp waiters(id), do: ShellJobs.waiters(id, 1_000)

  test "starts a job running, lists it, and kills it", %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)
    assert [%{id: ^id, status: :running, command: "sleep 30"}] = ShellJobs.list(key)

    assert :ok = ShellJobs.kill(key, id)
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, _code}, 1_000
    assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
  end

  # `kill/2` also arms the manager's five-second fallback for a job whose
  # exec-port `:DOWN` never arrives. That timer always fires in the end —
  # normally after the job has already finished, where it must do nothing — so
  # reaching it by waiting would cost the suite five seconds, and reaching it by
  # luck made this file's coverage depend on where in the run the last kill fell
  # (four stale timers fired in one full-suite seed and none in another). This is
  # that timer's own message to the manager, i.e. `handle_info/2`'s contract.
  test "a kill-finalize that arrives after the exit changes nothing", %{key: key, tmp: tmp} do
    {space_id, name} = key
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

    id = start_running!("sleep 30", tmp, key)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, status: :running}]}}, 1_000

    assert :ok = ShellJobs.subscribe(key, id, self())
    assert :ok = ShellJobs.kill(key, id)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, killed: true}]}}, 1_000
    assert_receive {:shell_job_exit, ^id, code}, 1_000
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}, 1_000

    send(ShellJobs.name(), {:kill_finalize, id})

    # A call to the manager is queued behind that message — same sender, same
    # receiver — so the fallback has run when this returns. It must leave the
    # recorded exit alone and broadcast nothing: the job is no longer
    # `:running`, so there is nothing to finalize.
    assert [%{id: ^id, status: :exited, exit_code: ^code}] = ShellJobs.list(key)
    refute_received {:shell_jobs, _}
  end

  test "reports the log path the agent can read, not the manager's own", %{key: key, tmp: tmp} do
    assert {:ok, message} = start_background("sleep 30", tmp, key)
    assert [%{id: id, log_path: log_path}] = ShellJobs.list(key)

    # The space dir is bound at /tmp and the agent's own dir is its
    # basename, so the log the sandbox sees is /tmp/<agent>/shell-jobs/...
    assert log_path == "/tmp/#{Path.basename(tmp)}/shell-jobs/#{id}.log"
    assert message =~ "(log: #{log_path})"

    # The manager still writes the log under its own scratch directory.
    assert File.exists?(Path.join([tmp, "shell-jobs", "#{id}.log"]))
  end

  test "removes the staged script from the host once the job exits (nested tmp)" do
    # A real space id: `broadcast/2` is guarded on `is_integer(space_id)`, and
    # the job-list broadcast is the fence below.
    key = {1, "script-cleanup-#{System.unique_integer([:positive])}"}

    # The real scratch shape is <root>/space-<id>/<agent-name>. With a
    # flat scratch dir the script's path inside the sandbox happens to equal
    # the path the manager writes, which is exactly why a flat-dir test
    # cannot catch a broken removal (the manager would `File.rm` a path that
    # happens to exist).
    root = Path.join(System.tmp_dir!(), "nest_jobs_script_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-1", "agent-scripts"])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      rm_tmp!(root, "nest_jobs_script_")
    end)

    # Subscribe to the topic *before* the job exists. `true` exits in about a
    # millisecond and PubSub has no replay, so a subscription that lands after
    # `finish_job/3`'s broadcast never sees that frame. It is not a visible
    # failure either: `ShellJobs.subscribe/3` has a late-subscribe clause that
    # still sends `{:shell_job_exit, …}` for an already-exited job, so the exit
    # frame still arrives and only the `assert_receive` below it fails — with an
    # empty mailbox, which reads like a hang. The broadcast test further down
    # subscribes first for the same reason.
    {space_id, name} = key
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

    {:ok, _message} = start_background("true", tmp, key)
    assert [%{id: id}] = ShellJobs.list(key)

    assert :ok = ShellJobs.subscribe(key, id, self())
    # Measured: a whole `bwrap` + `true` start->exit->`DOWN`->manager cycle is
    # 10-20 ms, and 3 `--cover` runs of this file under 16 CPU burners were 18
    # tests, 0 failures each.
    assert_receive {:shell_job_exit, ^id, 0}, 500

    # `finish_job/3` removes the host script and *then* broadcasts the job list,
    # so the broadcast is the happens-after event for "the script is gone". It
    # runs in one callback, so a call to the manager returns only after the
    # broadcast has been sent and — `Phoenix.PubSub.broadcast/3` being a
    # synchronous send to local subscribers — the frame is already in our
    # mailbox. That is the barrier; no clock is needed. (The start's own frame,
    # where the job is still `:running`, is left in the mailbox by
    # `assert_received` and cannot satisfy this pattern.)
    assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
    assert_received {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}

    assert Path.wildcard(Path.join(tmp, ".nest-cmd-*.sh"), match_dot: true) == []
  end

  test "a subscribe that lands after the exit still reports it", %{key: key, tmp: tmp} do
    {:ok, _message} = start_background("true", tmp, key)
    assert [%{id: id}] = ShellJobs.list(key)

    # The already-exited arm of `handle_call({:subscribe, ...})` fires only when
    # the subscribe arrives after the job exited, which is what makes it a race
    # to reach at all. `list/1` is a call to the manager, so it cannot return
    # before the exit has been recorded: waiting on it is a happens-after
    # barrier, not a clock. (`true` exits in about a millisecond, so this is one
    # poll in practice.)
    eventually(
      fn -> match?([%{id: ^id, status: :exited}], ShellJobs.list(key)) end,
      timeout: 1_000
    )

    assert :ok = ShellJobs.subscribe(key, id, self())

    # No timeout on purpose: `handle_call` sends the message before it replies,
    # so it is already in the mailbox when `subscribe/3` returns. If the arm is
    # not taken the message never arrives and this fails — deterministically.
    assert_received {:shell_job_exit, ^id, 0}
  end

  test "enforces the per-agent cap and frees a slot on exit", %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)

    assert {:error, message} = start_background("sleep 30", tmp, key)
    assert message =~ "limit reached"

    assert :ok = ShellJobs.kill(key, id)
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, _code}, 1_000

    assert {:ok, _} = start_background("sleep 30", tmp, key)
  end

  test "a command that exits within the grace window returns its output", %{key: key, tmp: tmp} do
    assert {:ok, output} = start_background("echo hello", tmp, key, grace_ms: 500)
    assert output == "hello\n"
  end

  test "captures the output of a job that exits after the grace window", %{key: key, tmp: tmp} do
    id = start_running!("sleep 0.2; echo late", tmp, key)

    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, 0}, 1_000
    assert {:ok, "late\n"} = ShellJobs.output(key, id)
  end

  test "caps.shell.background = 0 disables background jobs", %{key: key, tmp: tmp} do
    caps = %{
      "net" => false,
      "fs" => %{"read" => ["/"], "write" => ["/tmp"]},
      "shell" => %{"background" => 0}
    }

    assert {:error, message} =
             ShellCmd.execute("sleep 30", Mounts.new(File.cwd!(), tmp), caps,
               background: true,
               agent_key: key,
               grace_ms: 0
             )

    assert message =~ "disabled"
  end

  test "stop_all removes every job for an agent", %{key: key, tmp: tmp} do
    _id = start_running!("sleep 30", tmp, key)
    assert :ok = ShellJobs.stop_all(key)
    assert ShellJobs.list(key) == []
  end

  test "live_in_space?/1 is true only while a job in that space is running" do
    # Its own space id, not the fixture's shared `1`: this module is `async`, so
    # a concurrent test's job in space 1 would make the assertion pass whether or
    # not this test's job is live.
    space_id = System.unique_integer([:positive])
    key = {space_id, "agent-#{System.unique_integer([:positive])}"}
    root = Path.join(System.tmp_dir!(), "nest_jobs_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-#{space_id}", elem(key, 1)])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      rm_tmp!(root, "nest_jobs_")
    end)

    # Nothing tracked at all.
    refute ShellJobs.live_in_space?(space_id)

    id = start_running!("sleep 30", tmp, key)
    assert ShellJobs.live_in_space?(space_id)
    # The answer is the *space's*, not "any job anywhere".
    refute ShellJobs.live_in_space?(space_id + 1)

    # A finished job is retained for `shell-list`/`shell-wait`, so it is not
    # live: the exit message is sent before the status flips, and the call below
    # is queued behind that same callback.
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert :ok = ShellJobs.kill(key, id)
    assert_receive {:shell_job_exit, ^id, _code}, 1_000
    refute ShellJobs.live_in_space?(space_id)

    # ... and `stop_all/1` drops the agent's jobs, so nothing is live after it.
    assert {:ok, message} = start_background("sleep 30", tmp, key)
    assert message =~ "Started background job"
    assert ShellJobs.live_in_space?(space_id)

    assert :ok = ShellJobs.stop_all(key)
    refute ShellJobs.live_in_space?(space_id)
  end

  test "keeps the scratch while a live agent owns the key, then removes it" do
    # `TmpSpace.create` builds the real scratch path (`/tmp/nest/<pid>/space-<id>/<name>`),
    # which is the path `cleanup_agent_key/2` derives from the key — unlike the
    # fixture `tmp`, so the manager's removal is observable here.
    space_id = System.unique_integer([:positive])
    name = "incarnation-#{System.unique_integer([:positive])}"
    key = {space_id, name}
    tmp = TmpSpace.create(space_id, name, "bwrap")
    test_pid = self()

    on_exit(fn -> TmpSpace.cleanup(space_id, name, "bwrap") end)

    # A live incarnation registered under the key. The scratch path is derived
    # from the key, so a monitor for a *previous* incarnation can fire after this
    # one starts; the removal must refuse while a live agent owns the path.
    owner =
      spawn(fn ->
        {:ok, _} = Elixir.Registry.register(Nest.Agents.Registry, key, nil)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    assert File.dir?(tmp)

    # The manager's removal path, refused because the key has a live owner.
    assert :ok = ShellJobs.stop_all(key)
    assert File.dir?(tmp)

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1_000

    # With no live owner, the same path removes it.
    assert :ok = ShellJobs.stop_all(key)
    refute File.exists?(tmp)
  end

  test "jobs die with their agent, which says so to its waiters and its clients", %{
    key: {space_id, name} = key,
    tmp: tmp
  } do
    agent = spawn(fn -> receive do: (:never -> :ok) end)

    assert {:ok, _} = start_background("sleep 30", tmp, key, agent_pid: agent)
    assert [%{id: id}] = ShellJobs.list(key)

    # A waiter that outlives the agent: the tool worker behind a blocking
    # `shell-wait` is a task under `Nest.Agents.TaskSupervisor`, a sibling of
    # the agent supervisor, so the test process stands in for it.
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert self() in waiters(id)

    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 1_000

    # `drop_agent/3` does all of a dropped agent's work in a single callback —
    # stop the jobs, tell the waiters why, remove the scratch, then broadcast —
    # so a call to the manager returns only after both frames below have been
    # sent, and `Phoenix.PubSub.broadcast/3` delivers to local subscribers
    # synchronously. Reading the manager (the idiom `waiters/1` above uses) is
    # therefore the barrier, and neither assertion needs a clock of its own.
    assert ShellJobs.list(key) == []

    # The job is gone, and both notifications are the evidence: the frame is
    # broadcast after the drop, and the waiter is told why rather than left to
    # wait out its timeout. `{:shell_job_exit, …}` would be a lie — there is no
    # exit code.
    assert_received {:shell_jobs, %{jobs: []}}
    assert_received {:shell_job_gone, ^id}
    refute_received {:shell_job_exit, ^id, _code}

    assert waiters(id) == []
  end

  test "unknown job ids report :not_found", %{key: key} do
    assert {:error, :not_found} = ShellJobs.status(key, "job-999")
    assert {:error, :not_found} = ShellJobs.output(key, "job-999")
    assert {:error, :not_found} = ShellJobs.kill(key, "job-999")
    assert {:error, :not_found} = ShellJobs.subscribe(key, "job-999", self())
  end

  test "unsubscribe removes the caller from the job's waiters", %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)

    assert :ok = ShellJobs.subscribe(key, id, self())
    assert self() in waiters(id)

    assert :ok = ShellJobs.unsubscribe(key, id, self())
    refute self() in waiters(id)

    # Idempotent: a second unsubscribe (or one for an unknown job) is a no-op.
    assert :ok = ShellJobs.unsubscribe(key, id, self())
    assert :ok = ShellJobs.unsubscribe(key, "job-999", self())
  end

  test "list returns jobs newest-first" do
    name = "order-agent-#{System.unique_integer([:positive])}"
    key = {7, name}
    root = Path.join(System.tmp_dir!(), "nest_jobs_order_#{System.unique_integer([:positive])}")
    # A real scratch shape: the *space* dir is the bind root, so a scratch that
    # is a direct child of `/tmp` is one the sandbox refuses.
    tmp = Path.join([root, "space-1", name])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      rm_tmp!(root, "nest_jobs_order_")
    end)

    ids =
      for i <- 1..11 do
        {:ok, id, _log} =
          ShellJobs.start_job(%{
            agent_key: key,
            command: "true #{i}",
            script_sandbox: stage_script!(tmp),
            script_path: nil,
            mounts: Mounts.new(nil, tmp),
            max_jobs: 100
          })

        id
      end

    # Newest first: a listing is read to find what just ran. `trim/2` sorts the
    # other way on purpose, because it deletes the oldest.
    assert ShellJobs.list(key) |> Enum.map(& &1.id) == Enum.reverse(ids)
  end

  # A job's command line is the backend's to build, from the *staged* script
  # (`Nest.Sandbox.Backend.job_spec/4`) — a job's output has to reach a log file
  # inside the environment, which only the backend can arrange. So a test that
  # starts one directly has to have staged one, exactly as `ShellCmd` does.
  defp stage_script!(tmp) do
    dir = Paths.stage_dir(tmp)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "run.sh"), "exit 0\n")
    Path.join(Paths.stage_dir_sandbox(tmp), "run.sh")
  end

  test "kill broadcasts an updated job list" do
    name = "bcast-agent-#{System.unique_integer([:positive])}"
    key = {7, name}
    root = Path.join(System.tmp_dir!(), "nest_jobs_bcast_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-1", name])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      if String.contains?(root, "nest_jobs_bcast"), do: File.rm_rf(root)
    end)

    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:7:#{name}")

    id = start_running!("sleep 30", tmp, key)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id}]}}, 1_000

    # The pin for the converted barrier in the nested-tmp test: the broadcast is
    # the happens-after event for `finish_job/3`'s script removal, so no
    # `:exited` frame exists while the job is still running.
    refute_received {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}

    assert :ok = ShellJobs.kill(key, id)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, killed: true}]}}, 1_000
  end

  # The space edit's quiesce: a running job is work in the environment that is
  # about to change, so it is stopped — but the agent is not going away, so the
  # key, the job's history and the scratch all have to survive (unlike
  # `stop_all/1`, which drops them).
  test "stop_jobs stops the running jobs and keeps the key, history and scratch",
       %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)
    assert [%{id: ^id, status: :running}] = ShellJobs.list(key)

    # Something in the scratch that is not the job's script: the offloads a
    # `stop_all/1` would take with it.
    offload = Path.join(tmp, "offload.txt")
    File.write!(offload, "kept")

    assert :ok = ShellJobs.stop_jobs(key)

    # The stop is a kill: the manager learns the exit asynchronously, so the
    # status becomes `:exited` a moment later. Stopped, not forgotten: the job is
    # still listed.
    eventually(fn ->
      case ShellJobs.list(key) do
        [%{id: ^id, status: status}] -> status != :running
        _other -> false
      end
    end)

    # The key still owns its history, and the scratch is untouched.
    assert {:ok, _status} = ShellJobs.status(key, id)
    assert File.read!(offload) == "kept"

    # A second stop is a no-op, and the key still works: a new job starts on it
    # (and is listed alongside the stopped one, because the history survived).
    assert :ok = ShellJobs.stop_jobs(key)
    assert {:ok, _message} = start_background("sleep 30", tmp, key)
    assert length(ShellJobs.list(key)) == 2
  end

  describe "the job log on a container scratch" do
    test "is the container's own file: the manager writes nothing, and reads through it" do
      mounts = container_mounts()
      path = Path.join(Mounts.scratch(mounts), "shell-jobs/job-1.log")
      {:ok, name} = Docker.container_name(mounts)

      # The command itself writes the log (its `tee`), so the manager appends
      # nothing: the bytes it receives on the exec's stream are that same output.
      assert :ok = JobLog.append(mounts, path, "chunk")

      # And it reads it through the container, because nothing on the host can.
      runner = scripted_runner(%{["exec"] => {"job output\n", 0}})

      assert JobLog.read(mounts, path, runner: runner) == "job output\n"
      assert calls() == [["exec", name, "cat", path]]

      assert :ok = JobLog.remove(mounts, path, runner: runner)
      assert List.last(calls()) == ["exec", name, "rm", "-f", path]
    end

    test "the path the command tees into is the path the manager reads back" do
      # The two halves of a docker job's log: the command writes it, because it
      # is the only thing that can, and the manager reads it through the
      # container. They have to agree on the file, or a job's output would be
      # written where nothing ever looks.
      mounts = container_mounts()
      log = Path.join(Mounts.scratch(mounts), "shell-jobs/job-1.log")
      {:ok, name} = Docker.container_name(mounts)

      assert {:ok, spec} = Docker.job_spec(mounts, nil, "/tmp/.cmds/nest-cmd-1.sh", log)
      assert payload(spec.command) =~ "tee " <> ShellEscape.escape(log)

      runner = scripted_runner(%{["exec"] => {"the job's output\n", 0}})

      assert JobLog.read(mounts, log, runner: runner) == "the job's output\n"
      assert calls() == [["exec", name, "cat", log]]
    end

    test "prepares nothing on the host, because the scratch is not on the host" do
      mounts = container_mounts()

      assert :ok =
               JobLog.prepare(mounts, Path.join(Mounts.scratch(mounts), "shell-jobs/job-1.log"))

      refute File.exists?(Mounts.scratch(mounts))
    end

    test "reads empty when the container is gone" do
      # Archiving a space removes its containers, and a job record can outlive
      # one. An unreadable log is an empty one, exactly as a missing host file is.
      mounts = container_mounts()
      path = Path.join(Mounts.scratch(mounts), "shell-jobs/job-1.log")
      runner = fn _argv -> {"Error response from daemon: No such container\n", 1} end

      assert JobLog.read(mounts, path, runner: runner) == ""
    end
  end

  # A docker call's scratch is the *container's* `/tmp/<agent>`, so this is a
  # path nothing on the host may hold.
  defp container_mounts do
    Mounts.new(
      nil,
      Path.join("/tmp", "log-agent-#{System.unique_integer([:positive])}"),
      "docker",
      7
    )
  end
end
