defmodule Nest.Tools.ShellJobsTest do
  use ExUnit.Case, async: true

  import Eventually

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Messages.{ToolCall, ToolResult}
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools
  alias Nest.Tools.ShellCmd

  setup do
    name = "agent-#{System.unique_integer([:positive])}"
    key = {:test, name}
    tmp = Path.join(System.tmp_dir!(), "nest_tools_jobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      File.rm_rf(tmp)
    end)

    context = %{space_id: :test, agent_name: name, agent_pid: self(), caps: nil}
    %{key: key, tmp: tmp, context: context}
  end

  defp start_job!(command, tmp, key) do
    {:ok, _} =
      ShellCmd.execute(command, "/tmp", tmp, nil, background: true, agent_key: key, grace_ms: 0)

    assert [%{id: id}] = ShellJobs.list(key)
    id
  end

  defp invoke(tool, args, context), do: tool.function.(args, context)

  # The tool's caller must not be left registered for the job's exit.
  # The manager owns the waiter list, so read it directly instead of
  # racing an OS kill against a fixed receive timeout.
  defp waiters(id), do: Map.get(:sys.get_state(ShellJobs).waiters, id, [])

  # `echo` is fast, but the OS decides when it exits. Poll the manager's
  # authoritative status instead of racing the `shell-wait` timeout.
  defp wait_until_exited(key, id) do
    assert eventually(fn -> match?({:ok, {:exited, _}}, ShellJobs.status(key, id)) end,
             timeout: 5_000
           )
  end

  test "shell-list reports the agent's jobs", %{key: key, tmp: tmp, context: context} do
    assert {:ok, "No background jobs."} =
             invoke(Tools.get_function("shell-list", nil, nil), %{}, context)

    id = start_job!("sleep 30", tmp, key)

    assert {:ok, text} = invoke(Tools.get_function("shell-list", nil, nil), %{}, context)
    assert text =~ "- #{id}: running"
    assert text =~ "sleep 30"
  end

  test "shell-wait returns the output and exit code of a finished job", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    id = start_job!("echo done", tmp, key)
    wait_until_exited(key, id)

    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-wait", nil, nil),
               %{"id" => id, "timeout" => 500},
               context
             )

    assert text =~ "exited with code 0"
    assert text =~ "done"
  end

  test "shell-wait abandons the wait on stop_chat without killing the job", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    id = start_job!("sleep 30", tmp, key)
    send(self(), {:stop_chat, self()})

    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-wait", nil, nil),
               %{"id" => id, "timeout" => 500},
               context
             )

    assert text =~ "Stopped waiting"
    assert [%{id: ^id, status: :running}] = ShellJobs.list(key)
    refute self() in waiters(id)
  end

  test "shell-wait timeout unsubscribes the caller", %{key: key, tmp: tmp, context: context} do
    id = start_job!("sleep 30", tmp, key)

    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-wait", nil, nil),
               %{"id" => id, "timeout" => 10},
               context
             )

    assert text =~ "Timed out"
    refute self() in waiters(id)
  end

  test "shell-kill stops a running job", %{key: key, tmp: tmp, context: context} do
    id = start_job!("sleep 30", tmp, key)

    assert {:ok, text} =
             invoke(Tools.get_function("shell-kill", nil, nil), %{"id" => id}, context)

    assert text =~ "Killed background job #{id}"
    assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
  end

  test "unknown ids are reported as errors", %{context: context} do
    assert {:error, _} =
             invoke(Tools.get_function("shell-wait", nil, nil), %{"id" => "job-999"}, context)

    assert {:error, _} =
             invoke(Tools.get_function("shell-kill", nil, nil), %{"id" => "job-999"}, context)
  end

  test "shell-cmd background via BatchSizer is keyed to the calling agent", %{
    key: {space_id, name},
    tmp: tmp
  } do
    tool = Tools.get_function("shell-cmd", "/tmp", tmp)

    ctx = %{
      tools: [tool],
      caps: nil,
      context_limit: 100_000,
      messages: [],
      tmp_path: tmp,
      agent_pid: self(),
      agent_name: name,
      space_id: space_id
    }

    tc = %ToolCall{
      id: "c1",
      name: "shell-cmd",
      arguments: %{"command" => "sleep 30", "background" => true}
    }

    assert [%ToolResult{content: content}] = BatchSizer.run([tc], ctx)
    assert content =~ "Started background job"

    # The job is owned by the real key, not {nil, nil} / {:unknown, :unknown}.
    assert [%{id: id, log_path: log_path}] = ShellJobs.list({space_id, name})

    # The agent is told the path it can actually read from inside the
    # sandbox, not the host path the manager writes.
    assert log_path == "/tmp/#{Path.basename(tmp)}/shell-jobs/#{id}.log"
    assert content =~ "(log: #{log_path})"

    assert ShellJobs.list({nil, nil}) == []
    assert ShellJobs.list({:unknown, :unknown}) == []
  end
end
