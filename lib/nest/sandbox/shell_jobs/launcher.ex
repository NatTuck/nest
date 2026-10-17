defmodule Nest.Sandbox.ShellJobs.Launcher do
  @moduledoc """
  Stages a background shell job's log file and starts its process.

  Called by `Nest.Sandbox.ShellJobs` from inside its `:start_job`
  callback, so this runs in the manager's own process: the `:exec`
  monitor and the job's log file both have to live and die with the
  manager, which is why the work is not handed to a task. Extracted
  from `Nest.Sandbox.ShellJobs` to keep that module under the
  source-file line cap.
  """

  alias Nest.Sandbox
  alias Nest.Sandbox.{Backend, Mounts}
  alias Nest.Sandbox.ShellJobs.JobLog

  # The subdirectory the job logs live in beneath the agent's own dir.
  @log_subdir "shell-jobs"

  # The erlexec options every background job starts with; `exec_options/1`
  # prepends a working directory when the backend's spec carries one.
  @exec_options [:stdout, :stderr, :monitor, {:stdin, :null}, {:kill_timeout, 5000}]

  @doc """
  Build the job record for `attrs` and start its process.

  `job_id` is the id the manager allocated (`"job-<n>"`). The log is
  `<scratch>/shell-jobs/<job_id>.log`, which under every backend whose scratch
  is a host directory is a real file the manager writes, and under `"docker"` is
  a path in the container that the command itself writes — so the path handed
  back is the path the *sandbox* sees
  (`/tmp/<agent-name>/shell-jobs/<id>.log`), which is the only spelling that
  resolves inside a `shell-cmd` either way.

  The command line comes from the backend's job spec
  (`Nest.Sandbox.Backend.job_spec/4`), which needs the mode's caps and the
  script's sandbox spelling: a job whose output has to reach a log file inside
  the environment is a command line only the backend can build. So a background
  job starts in exactly the environment its backend builds for a foreground one.

  Returns `{:ok, job, sandbox_log_path}` or `{:error, reason}`.
  """
  @spec launch(map(), {term(), term()}, String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def launch(attrs, agent_key, job_id) do
    mounts = Map.fetch!(attrs, :mounts)
    scratch = Mounts.scratch(mounts)
    log_path = Path.join([scratch, @log_subdir, "#{job_id}.log"])

    sandbox_log_path =
      Path.join([Sandbox.sandbox_tmp_path(scratch), @log_subdir, "#{job_id}.log"])

    with :ok <- JobLog.prepare(mounts, log_path),
         {:ok, spec} <- job_spec(attrs, mounts, sandbox_log_path),
         {:ok, erl_pid, os_pid} <- run_process(spec) do
      job = %{
        id: job_id,
        agent_key: agent_key,
        command: Map.fetch!(attrs, :command),
        script_path: Map.get(attrs, :script_path),
        mounts: mounts,
        log_path: log_path,
        sandbox_log_path: sandbox_log_path,
        erl_pid: erl_pid,
        os_pid: os_pid,
        status: :running,
        exit_code: nil,
        killed: false,
        started_at: DateTime.utc_now()
      }

      {:ok, job, sandbox_log_path}
    else
      {:error, reason} ->
        # Don't leave the empty log file (or partial dir) behind when the
        # process never started.
        JobLog.remove(mounts, log_path)
        {:error, start_error(reason)}
    end
  end

  defp job_spec(attrs, mounts, sandbox_log_path) do
    Backend.job_spec(
      mounts,
      Map.get(attrs, :caps),
      Map.fetch!(attrs, :script_sandbox),
      sandbox_log_path
    )
  end

  defp run_process(spec) do
    :exec.run(
      to_charlist(spec.command),
      exec_options(spec.cd)
    )
  end

  # `{:cd, dir}` is how a backend with no chdir of its own starts the job in
  # the right directory (see `Nest.Tools.ShellCmd.exec_options/2`).
  defp exec_options(nil), do: @exec_options

  defp exec_options(dir), do: [{:cd, dir} | @exec_options]

  defp start_error(reason) when is_binary(reason), do: "Failed to start process: #{reason}"
  defp start_error(reason) when is_atom(reason), do: "Failed to start process: #{reason}"
  defp start_error({:error, reason}), do: start_error(reason)
  defp start_error(reason), do: "Failed to start process: #{inspect(reason)}"
end
