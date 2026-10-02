defmodule Nest.Sandbox.ShellJobsTest do
  use ExUnit.Case, async: true

  import Eventually

  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools.ShellCmd

  setup do
    key = {:test, "agent-#{System.unique_integer([:positive])}"}
    tmp = Path.join(System.tmp_dir!(), "nest_jobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      File.rm_rf(tmp)
    end)

    %{key: key, tmp: tmp}
  end

  defp start_background(command, tmp, key, opts \\ []) do
    opts = Keyword.merge([background: true, agent_key: key, grace_ms: 0], opts)
    ShellCmd.execute(command, "/tmp", tmp, nil, opts)
  end

  # Start a job that stays running past the grace window and return its id.
  defp start_running!(command, tmp, key) do
    assert {:ok, message} = start_background(command, tmp, key)
    assert message =~ "Started background job"

    assert [%{id: id}] = ShellJobs.list(key)
    id
  end

  test "starts a job running, lists it, and kills it", %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)
    assert [%{id: ^id, status: :running, command: "sleep 30"}] = ShellJobs.list(key)

    assert :ok = ShellJobs.kill(key, id)
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, _code}, 500
    assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
  end

  test "enforces the per-agent cap and frees a slot on exit", %{key: key, tmp: tmp} do
    id = start_running!("sleep 30", tmp, key)

    assert {:error, message} = start_background("sleep 30", tmp, key)
    assert message =~ "limit reached"

    assert :ok = ShellJobs.kill(key, id)
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, _code}, 500

    assert {:ok, _} = start_background("sleep 30", tmp, key)
  end

  test "a command that exits within the grace window returns its output", %{key: key, tmp: tmp} do
    assert {:ok, output} = start_background("echo hello", tmp, key, grace_ms: 500)
    assert output == "hello\n"
  end

  test "captures the output of a job that exits after the grace window", %{key: key, tmp: tmp} do
    id = start_running!("sleep 0.2; echo late", tmp, key)

    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, 0}, 500
    assert {:ok, "late\n"} = ShellJobs.output(key, id)
  end

  test "caps.shell.background = 0 disables background jobs", %{key: key, tmp: tmp} do
    caps = %{
      "net" => false,
      "fs" => %{"read" => ["/"], "write" => ["/tmp"]},
      "shell" => %{"background" => 0}
    }

    assert {:error, message} =
             ShellCmd.execute("sleep 30", "/tmp", tmp, caps,
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

  test "jobs die with their agent", %{key: key, tmp: tmp} do
    agent = spawn(fn -> receive do: (:never -> :ok) end)

    assert {:ok, _} = start_background("sleep 30", tmp, key, agent_pid: agent)

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, ^agent, :killed}, 500

    assert eventually(fn -> ShellJobs.list(key) == [] end, timeout: 500)
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
    assert :ok = ShellJobs.unsubscribe(key, id, self())

    # Synchronize on the job's exit through a separate observer, then
    # assert the unsubscribed caller received no stray exit message.
    parent = self()

    observer =
      spawn(fn ->
        receive do
          {:shell_job_exit, ^id, code} -> send(parent, {:observed_exit, id, code})
        end
      end)

    assert :ok = ShellJobs.subscribe(key, id, observer)
    assert :ok = ShellJobs.kill(key, id)

    assert_receive {:observed_exit, ^id, _code}, 500
    refute_received {:shell_job_exit, ^id, _code}

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
      File.rm_rf(tmp)
    end)

    ids =
      for i <- 1..11 do
        {:ok, id, _log} =
          ShellJobs.start_job(%{
            agent_key: key,
            command: "true #{i}",
            bwrap: "true",
            script_path: nil,
            tmp_path: tmp,
            max_jobs: 100
          })

        id
      end

    assert ShellJobs.list(key) |> Enum.map(& &1.id) == ids
  end

  test "kill broadcasts an updated job list" do
    name = "bcast-agent-#{System.unique_integer([:positive])}"
    key = {7, name}
    tmp = Path.join(System.tmp_dir!(), "nest_jobs_bcast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      File.rm_rf(tmp)
    end)

    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:7:#{name}")

    id = start_running!("sleep 30", tmp, key)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id}]}}, 500

    assert :ok = ShellJobs.kill(key, id)
    assert_receive {:shell_jobs, %{jobs: [%{id: ^id, killed: true}]}}, 500
  end
end
