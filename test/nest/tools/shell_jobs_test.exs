defmodule Nest.Tools.ShellJobsTest do
  use ExUnit.Case, async: true

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

    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-wait", nil, nil),
               %{"id" => id, "timeout" => 5_000},
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
               %{"id" => id, "timeout" => 5_000},
               context
             )

    assert text =~ "Stopped waiting"
    assert [%{id: ^id, status: :running}] = ShellJobs.list(key)
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
end
