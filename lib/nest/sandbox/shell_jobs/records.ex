defmodule Nest.Sandbox.ShellJobs.Records do
  @moduledoc """
  The manager's job map: how a record is added under its id, how finished records
  are bounded, and the staged script a record owns.

  `Nest.Sandbox.ShellJobs` owns the state (and the process); this module owns the
  map's shape and its retention. Split out for the source-file cap, like `Index`,
  `Waiters` and `Text`, and shared by `Nest.Sandbox.ShellJobs.Owned`, which adds a
  foreground call's record the same way `start_guarded/4` adds a background
  job's.
  """

  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.{Index, JobLog}

  @max_finished_per_agent 50

  @doc """
  Put `job` under its id, keeping the id counter ahead of every id in use.

  The counter allocates the next `"job-<n>"`, and both the background and the
  foreground path allocate from it, so it has to be monotone across the two.
  """
  @spec put(map(), map()) :: map()
  def put(state, job) do
    %{
      state
      | jobs: Map.put(state.jobs, job.id, job),
        next_id: max(state.next_id, id_number(job) + 1)
    }
  end

  @doc """
  Keep at most #{@max_finished_per_agent} finished jobs per agent; evict the
  oldest (deleting its log file).

  Only *finished* jobs are evicted: a running job is live work, however old, and
  a foreground `shell-cmd` call (#174) is as running as a background one.
  """
  @spec trim(map(), ShellJobs.agent_key()) :: map()
  def trim(state, agent_key) do
    finished =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == agent_key and match?({:exited, _}, &1.status)))
      |> Enum.sort_by(& &1.started_at, DateTime)

    excess = length(finished) - @max_finished_per_agent

    if excess > 0 do
      finished
      |> Enum.take(excess)
      |> Enum.reduce(state, fn job, acc ->
        JobLog.remove(job.mounts, job.log_path)
        %{acc | jobs: Map.delete(acc.jobs, job.id), waiters: Map.delete(acc.waiters, job.id)}
      end)
    else
      state
    end
  end

  @doc """
  Append a streamed chunk to the log of the running job whose OS pid is `os_pid`,
  and return `state` — the manager's own jobs' output path.

  A chunk whose process the manager does not track changes nothing (a job that
  already finished keeps its `os_pid`, so trailing output still lands in its
  log). A foreground call's output never comes this way: its worker holds the
  port (`Nest.Sandbox.ShellJobs.Owned.append/2`).
  """
  @spec append_output(map(), non_neg_integer(), iodata()) :: map()
  def append_output(state, os_pid, data) do
    if job = Index.by_os_pid(state, os_pid),
      do: JobLog.append(job.mounts, job.log_path, data)

    state
  end

  @doc """
  Remove the job's staged script, when it has one.

  `script_path` is the staging path `Nest.Tools.ShellCmd.Transcript.stage/2`
  writes to; the spelling the backend's command line uses is a different thing
  and must never be passed here. A registered foreground call has none: its tool
  worker removes its own script in `ShellCmd.exec_staged/7`'s `after`.
  """
  @spec remove_script(map()) :: :ok
  def remove_script(%{script_path: nil}), do: :ok

  def remove_script(%{script_path: path}) do
    File.rm(path)
    :ok
  end

  defp id_number(%{id: "job-" <> n}), do: String.to_integer(n)
end
