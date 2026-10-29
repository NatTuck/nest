defmodule Nest.Tools.ShellJobsTest do
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Messages.{ToolCall, ToolResult}
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools
  alias Nest.Tools.ShellCmd

  setup do
    name = "agent-#{System.unique_integer([:positive])}"
    key = {:test, name}
    root = Path.join(System.tmp_dir!(), "nest_tools_jobs_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-1", name])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      if String.contains?(root, "nest_tools_jobs"), do: File.rm_rf(root)
    end)

    context = %{space_id: :test, agent_name: name, agent_pid: self(), caps: nil}
    %{key: key, tmp: tmp, context: context}
  end

  # The id of the job this call started. The manager may already hold others
  # (a finished job is retained), so the new id is the one that was not there
  # before — and there must be exactly one.
  defp start_job!(command, tmp, key) do
    before = key |> ShellJobs.list() |> Enum.map(& &1.id)

    {:ok, _} =
      ShellCmd.execute(command, Mounts.new(File.cwd!(), tmp), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    assert [%{id: id}] = Enum.reject(ShellJobs.list(key), &(&1.id in before))
    id
  end

  defp invoke(tool, args, context), do: tool.function.(args, context)

  # A second agent in the caller's space, with its own scratch: the sibling a
  # space listing has to show and a space kill has to reach.
  defp sibling_agent(key, tmp, tag) do
    sibling = {elem(key, 0), "#{tag}-#{System.unique_integer([:positive])}"}
    scratch = Path.join(Path.dirname(tmp), elem(sibling, 1))
    File.mkdir_p!(scratch)
    on_exit(fn -> ShellJobs.stop_all(sibling) end)
    {sibling, scratch}
  end

  # `echo` is fast, but the OS decides when it exits. Wait for the manager's
  # exit event instead of polling its status; `subscribe/3` sends the frame
  # immediately for a job that has already exited, so nothing can be missed.
  defp wait_until_exited(key, id) do
    assert :ok = ShellJobs.subscribe(key, id, self())
    assert_receive {:shell_job_exit, ^id, _code}, 1_000
  end

  # Issue #181: `shell-list` answers "what is running now". A finished job is a
  # transcript entry — the manager retains a bounded tail of them — and rendering
  # that tail buried the live one.
  test "shell-list lists only the running jobs and names the finished ones", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    tool = Tools.get_function("shell-list", Mounts.new(nil, nil))

    assert {:ok, "No shell jobs running."} = invoke(tool, %{}, context)

    # A finished job is not a row. It is still retrievable by id, so the count
    # is named in one sentence instead.
    finished = start_job!("echo done", tmp, key)
    wait_until_exited(key, finished)

    assert {:ok, text} = invoke(tool, %{}, context)

    # The empty answer first, then the sentence: the rows and the note are
    # separate lines so a row can never be glued onto the sentence.
    assert text ==
             "No shell jobs running.\n" <>
               "1 finished shell job is still retrievable by id (shell-wait)."

    refute text =~ "echo done"

    # The count is a count, and one is not "1 finished shell jobs". Two
    # finished jobs before anything runs: `caps["shell"]["background"]` allows
    # one *running* job at a time, and these are not running.
    second = start_job!("echo again", tmp, key)
    wait_until_exited(key, second)

    assert {:ok, text} = invoke(tool, %{}, context)

    assert text ==
             "No shell jobs running.\n" <>
               "2 finished shell jobs are still retrievable by id (shell-wait)."

    refute text =~ "echo again"

    # A running job is a row, and the sentence follows it on its own line.
    running = start_job!("sleep 30", tmp, key)

    assert {:ok, text} = invoke(tool, %{}, context)
    assert text =~ "- #{running}: running"
    assert text =~ "sleep 30"
    refute text =~ "echo done"

    assert text =~ "2 finished shell jobs are still retrievable by id (shell-wait)."

    # With nothing finished the sentence is absent, not "0 finished ...".
    {fresh, fresh_tmp} = sibling_agent(key, tmp, "list-fresh")
    fresh_id = start_job!("sleep 30", fresh_tmp, fresh)

    assert {:ok, fresh_text} =
             invoke(tool, %{}, %{context | agent_name: elem(fresh, 1)})

    assert fresh_text =~ "- #{fresh_id}: running"
    refute fresh_text =~ "finished"
  end

  test "shell-wait returns the output and exit code of a finished job", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    id = start_job!("echo done", tmp, key)
    wait_until_exited(key, id)

    # A job that has already finished reports its output in the result: there
    # is nothing to wait for, so the tool answers inline (issue #54) and the
    # caller's turn continues.
    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-wait", Mounts.new(nil, nil)),
               %{"id" => id, "timeout" => 500},
               context
             )

    assert text =~ "exited with code 0"
    assert text =~ "done"
  end

  test "shell-kill stops a running job", %{key: key, tmp: tmp, context: context} do
    id = start_job!("sleep 30", tmp, key)

    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-kill", Mounts.new(nil, nil)),
               %{"id" => id},
               context
             )

    assert text =~ "Killed shell job #{id}"
    assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
  end

  test "shell-list scope switches between the caller's jobs and the space's", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    {sibling, sibling_tmp} = sibling_agent(key, tmp, "list-sibling")

    id = start_job!("sleep 30", tmp, key)
    sibling_id = start_job!("sleep 30", sibling_tmp, sibling)

    tool = Tools.get_function("shell-list", Mounts.new(nil, nil))

    # The default is unchanged, and still the caller's own jobs only.
    assert {:ok, own} = invoke(tool, %{}, context)
    assert own =~ "- #{id}: running"
    refute own =~ sibling_id

    # The space listing shows both, each with the agent that owns it.
    assert {:ok, space} = invoke(tool, %{"scope" => "space"}, context)
    assert space =~ "- #{id} (owner: #{context.agent_name}): running"
    assert space =~ "- #{sibling_id} (owner: #{elem(sibling, 1)}): running"
    assert space =~ "sleep 30"

    # Anything else is refused, and the refusal names both values it accepts.
    assert {:error, message} = invoke(tool, %{"scope" => "agents"}, context)
    assert message =~ ~s("agent")
    assert message =~ ~s("space")

    # An empty space says so. A negative id is one no other test's fixture uses
    # (`System.unique_integer([:positive])`), so this space is really empty.
    empty = %{context | space_id: -System.unique_integer([:positive])}

    assert {:ok, "No shell jobs running in this space."} =
             invoke(tool, %{"scope" => "space"}, empty)
  end

  # The space scope lists the running jobs only too (#181), but it words the
  # finished ones differently: `shell-wait` is owner-scoped, so a sibling's
  # finished id is not retrievable by the caller — the sentence must not claim
  # it is.
  test "shell-list scope: space lists only running jobs, and promises no retrieval", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    {sibling, sibling_tmp} = sibling_agent(key, tmp, "list-space-finished")

    finished = start_job!("echo done", sibling_tmp, sibling)
    wait_until_exited(sibling, finished)

    tool = Tools.get_function("shell-list", Mounts.new(nil, nil))

    # The caller has no jobs of its own, so the space listing is the only place
    # the finished job could appear — and it does not.
    assert {:ok, text} = invoke(tool, %{"scope" => "space"}, context)

    assert text ==
             "No shell jobs running in this space.\n" <>
               "1 finished shell job is not listed."

    refute text =~ "echo done"
    # The agent scope's promise would be false here: no id was offered and
    # `shell-wait` would not answer for the sibling's job anyway.
    refute text =~ "retrievable"

    # Two finished jobs, and the count is a count.
    second = start_job!("echo again", sibling_tmp, sibling)
    wait_until_exited(sibling, second)

    assert {:ok, text} = invoke(tool, %{"scope" => "space"}, context)
    assert text =~ "2 finished shell jobs are not listed."

    # A sibling's *running* job is still a row, owner column and all.
    running = start_job!("sleep 30", sibling_tmp, sibling)

    assert {:ok, text} = invoke(tool, %{"scope" => "space"}, context)
    assert text =~ "- #{running} (owner: #{elem(sibling, 1)}): running"
    assert text =~ "2 finished shell jobs are not listed."
    refute text =~ "echo done"
  end

  test "shell-list scope: space names a job whose key names no agent", %{tmp: tmp} do
    # `Nest.Tools.agent_key/1` falls back to `{:unknown, :unknown}` for a caller
    # with neither a space nor a name, so a space listing must render the missing
    # owner rather than raise on a key that is not `{space_id, name}`.
    key = {:unknown, :unknown}
    on_exit(fn -> ShellJobs.stop_all(key) end)

    id = start_job!("sleep 30", tmp, key)
    assert %{agent: nil} = Enum.find(ShellJobs.list_space(:unknown), &(&1.id == id))

    # No `space_id` in the context, so the tool's own key is the fallback too.
    assert {:ok, text} =
             invoke(
               Tools.get_function("shell-list", Mounts.new(nil, nil)),
               %{"scope" => "space"},
               %{agent_pid: self()}
             )

    assert text =~ "- #{id} (owner: unknown): running"
  end

  test "shell-kill stops another agent's job in this space, and refuses another space's", %{
    key: key,
    tmp: tmp,
    context: context
  } do
    {sibling, sibling_tmp} = sibling_agent(key, tmp, "kill-sibling")

    # A space the caller is not in: a job id from here must not be reachable.
    outsider = {:other_space, "kill-outsider-#{System.unique_integer([:positive])}"}
    outsider_tmp = Path.join([Path.dirname(Path.dirname(tmp)), "space-other", elem(outsider, 1)])
    File.mkdir_p!(outsider_tmp)
    on_exit(fn -> ShellJobs.stop_all(outsider) end)

    sibling_id = start_job!("sleep 30", sibling_tmp, sibling)
    outsider_id = start_job!("sleep 30", outsider_tmp, outsider)

    tool = Tools.get_function("shell-kill", Mounts.new(nil, nil))

    assert {:ok, text} = invoke(tool, %{"id" => sibling_id}, context)
    assert text =~ "Killed shell job #{sibling_id}"
    assert text =~ "owned by #{elem(sibling, 1)}"
    assert [%{id: ^sibling_id, status: :exited, killed: true}] = ShellJobs.list(sibling)

    assert {:error, message} = invoke(tool, %{"id" => outsider_id}, context)
    assert message =~ "No such shell job: #{outsider_id}"
    assert [%{id: ^outsider_id, status: :running}] = ShellJobs.list(outsider)
  end

  test "unknown ids are reported as errors", %{context: context} do
    assert {:error, _} =
             invoke(
               Tools.get_function("shell-wait", Mounts.new(nil, nil)),
               %{"id" => "job-999"},
               context
             )

    assert {:error, _} =
             invoke(
               Tools.get_function("shell-kill", Mounts.new(nil, nil)),
               %{"id" => "job-999"},
               context
             )
  end

  test "shell-cmd background via BatchSizer is keyed to the calling agent", %{
    key: {space_id, name},
    tmp: tmp
  } do
    tool = Tools.get_function("shell-cmd", Mounts.new(File.cwd!(), tmp))

    ctx = %{
      tools: [tool],
      caps: nil,
      context_limit: 100_000,
      messages: [],
      mounts: Mounts.new(File.cwd!(), tmp),
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

    # The job is owned by the real key, not the `agent_key/1` fallback: a job
    # carries exactly one key, so listing it here rules the fallback out.
    assert [%{id: id, log_path: log_path}] = ShellJobs.list({space_id, name})

    # The agent is told the path it can actually read from inside the
    # sandbox, not the log file the manager writes.
    assert log_path == "/tmp/#{Path.basename(tmp)}/shell-jobs/#{id}.log"
    assert content =~ "(log: #{log_path})"
  end
end
