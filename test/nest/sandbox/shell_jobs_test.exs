defmodule Nest.Sandbox.ShellJobsTest do
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools.ShellCmd

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

    {:ok, _message} = start_background("true", tmp, key)
    assert [%{id: id}] = ShellJobs.list(key)

    # `finish_job/3` removes the host script and *then* broadcasts the job list,
    # so the broadcast is the happens-after event for "the script is gone".
    # Subscribe after the start (whose broadcast would be a different frame), so
    # the only frame this can match is the finish's; the payload names the job
    # and its exit, which is what pins the fence to that event.
    {space_id, name} = key
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, 0}, 1_000
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}, 1_000

    assert Path.wildcard(Path.join(tmp, ".nest-cmd-*.sh"), match_dot: true) == []
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

  test "keeps the scratch while a live agent owns the key, then removes it" do
    # `TmpSpace.create` builds the real scratch path (`/tmp/nest-<pid>/space-<id>/<name>`),
    # which is the path `cleanup_agent_key/2` derives from the key — unlike the
    # fixture `tmp`, so the manager's removal is observable here.
    space_id = System.unique_integer([:positive])
    name = "incarnation-#{System.unique_integer([:positive])}"
    key = {space_id, name}
    tmp = TmpSpace.create(space_id, name)
    test_pid = self()

    on_exit(fn -> TmpSpace.cleanup(space_id, name) end)

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

    # The job is gone, and both notifications are the evidence: the frame is
    # broadcast after the drop, and the waiter is told why rather than left to
    # wait out its timeout. `{:shell_job_exit, …}` would be a lie — there is no
    # exit code.
    assert_receive {:shell_jobs, %{jobs: []}}, 500
    assert_receive {:shell_job_gone, ^id}, 500
    refute_received {:shell_job_exit, ^id, _code}

    assert ShellJobs.list(key) == []
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

  test "list returns jobs oldest-first" do
    name = "order-agent-#{System.unique_integer([:positive])}"
    key = {7, name}
    tmp = Path.join(System.tmp_dir!(), "nest_jobs_order_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      rm_tmp!(tmp, "nest_jobs_order_")
    end)

    ids =
      for i <- 1..11 do
        {:ok, id, _log} =
          ShellJobs.start_job(%{
            agent_key: key,
            command: "true #{i}",
            bwrap: "true",
            script_path: nil,
            mounts: Mounts.new(nil, tmp),
            max_jobs: 100
          })

        id
      end

    assert ShellJobs.list(key) |> Enum.map(& &1.id) == ids
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
end
