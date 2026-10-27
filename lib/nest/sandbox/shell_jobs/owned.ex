defmodule Nest.Sandbox.ShellJobs.Owned do
  @moduledoc """
  The job record for a *foreground* `shell-cmd` call (issue #174).

  Every `shell-cmd` call is a shell job for as long as it runs. The tool worker
  keeps owning the `:exec` process — its streams, its deadline, its
  `[Command cancelled]` marker and its combined output are still
  `Nest.Tools.ShellCmd`'s — and this module owns only the *record*: the
  registration that makes the call visible, the log its output is appended to,
  and the finish that marks it exited. `Nest.Sandbox.ShellJobs` keeps that record
  in the same map as its background jobs, so `shell-list`, the job panel,
  `shell-kill` and the sidebar's running count treat a foreground call and a
  background job alike.

  That is the whole of issue #174: a batch moved to the background (a message
  arriving mid-batch) needs no promotion step, because the job was listed from
  the moment its command started.

  ## What is different from a background job

    * **The manager does not own the process.** `owner` is the tool worker that
      started it, which is why a kill is a message to that worker
      (`{:kill_job, id}`) rather than an `:exec.kill` from the manager: the worker
      is the process's owner and is already in its receive loop. The manager
      monitors the owner (`owner_ref`), so a worker that dies mid-command — the
      Stop path kills it right after its `{:stop_chat, _}` — cannot leave a job
      `:running` forever.
    * **The worker removes its own staged script** (`ShellCmd.exec_staged/7`'s
      `after`), so `script_path` is `nil` and `Records.remove_script/1` is a
      no-op for these records.
    * **It is not a background job**, so it is neither refused by nor counted
      against `caps.shell.background` (`Index.running_count/2` counts the jobs
      the manager started).
    * **It never delivers an `ExitNotice`** (`Nest.Sandbox.ShellJobs.finish_job/3`
      skips it for a record with an `owner`). The tool call's own result is the
      agent's report of what happened; a notice would be a second turn on the
      same call.
    * **Under `"docker"` its log stays empty.** A job's log there is the
      container's own file, which only a *background* job's command line arranges
      to write (its `tee`, `Nest.Sandbox.Backend.Docker.job_spec/4`), so
      `JobLog.append/3` has nowhere to put the bytes this worker collects. The
      call's own result is unaffected, and its listing, status and kill all still
      work.
  """

  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.{Frames, JobLog, Launcher, Records, Waiters}

  @doc """
  Build the record for the call `owner` is running, with `job_id` allocated by
  the manager and `attrs` carrying `:agent_key`, `:command`, `:mounts` and
  `:os_pid`.

  `{:error, reason}` when the log cannot be prepared: the caller runs the command
  anyway, unregistered, because a call nobody can list is better than a command
  nobody can run.
  """
  @spec new(map(), String.t(), pid()) :: {:ok, map()} | {:error, String.t()}
  def new(%{mounts: %Mounts{scratch: nil}}, _job_id, _owner),
    do: {:error, "a shell job needs a scratch directory for its log"}

  def new(attrs, job_id, owner) do
    mounts = Map.fetch!(attrs, :mounts)
    {log_path, sandbox_log_path} = Launcher.log_paths(mounts, job_id)

    case JobLog.prepare(mounts, log_path) do
      :ok -> {:ok, record(attrs, job_id, owner, mounts, log_path, sandbox_log_path)}
      {:error, reason} -> {:error, "Could not prepare the job log: #{inspect(reason)}"}
    end
  end

  @doc """
  Finish `job_id` with `code`: tell its waiters, trim the agent's finished history
  and broadcast the new list.

  A no-op for a job that is not running — a second finish, or one that arrived
  after a kill's fallback already ended it — so every path that ends a call can
  call this blindly. The `owner` guard is what keeps it to *this* module's
  records: a background job's id finishes through the manager's own
  `finish_job/3`, with its notice and its exec port.
  """
  @spec finish(map(), ShellJobs.job_id(), integer()) :: map()
  def finish(state, job_id, code) do
    case Map.get(state.jobs, job_id) do
      %{status: :running, owner: owner} = job when is_pid(owner) ->
        Process.demonitor(job.owner_ref, [:flush])

        state
        |> Map.update!(:waiters, &Waiters.notify_exit(&1, job.id, code))
        |> Records.put(%{job | status: {:exited, code}, exit_code: code})
        |> Records.trim(job.agent_key)
        |> Frames.broadcast(job.agent_key)

      _finished_or_gone ->
        state
    end
  end

  @doc """
  Append one output chunk to the job's log, so a log read mid-run — or after a
  kill — sees what the command has written so far.
  """
  @spec append(map(), iodata()) :: :ok | {:error, term()}
  def append(%{mounts: mounts, log_path: path}, data), do: JobLog.append(mounts, path, data)

  defp record(attrs, job_id, owner, mounts, log_path, sandbox_log_path) do
    %{
      id: job_id,
      agent_key: Map.fetch!(attrs, :agent_key),
      owner: owner,
      owner_ref: Process.monitor(owner),
      command: Map.fetch!(attrs, :command),
      mounts: mounts,
      log_path: log_path,
      sandbox_log_path: sandbox_log_path,
      script_path: nil,
      # The worker holds the exec port, so the manager has neither the port's
      # monitor pid nor a `:DOWN` from it; the fields exist because a record is
      # read by the same shaping (`Info`, `Index`) as a background job's.
      erl_pid: nil,
      os_pid: Map.fetch!(attrs, :os_pid),
      status: :running,
      exit_code: nil,
      killed: false,
      killed_by: nil,
      started_at: DateTime.utc_now()
    }
  end
end
