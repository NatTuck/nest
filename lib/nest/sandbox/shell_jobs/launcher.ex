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
  alias Nest.Sandbox.Mounts

  # The subdirectory the job logs live in beneath the agent's own dir.
  @log_subdir "shell-jobs"

  # The erlexec options every background job starts with; `exec_options/1`
  # prepends a working directory when the backend's spec carries one.
  @exec_options [:stdout, :stderr, :monitor, {:stdin, :null}, {:kill_timeout, 5000}]

  @doc """
  Build the job record for `attrs` and start its process.

  `job_id` is the id the manager allocated (`"job-<n>"`). The log is
  written to `<scratch>/shell-jobs/<job_id>.log` and handed back as the
  path the *sandbox* sees for it
  (`/tmp/<agent-name>/shell-jobs/<id>.log`) — the only spelling that
  resolves inside a `shell-cmd`.

  The command line and its working directory come from
  `Nest.Sandbox.Backend`'s spec (`attrs[:command_line]` / `attrs[:cd]`), so a
  background job starts in exactly the environment its backend builds for a
  foreground one.

  Returns `{:ok, job, sandbox_log_path}` or `{:error, reason}`.
  """
  @spec launch(map(), {term(), term()}, String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def launch(attrs, agent_key, job_id) do
    scratch = attrs |> Map.fetch!(:mounts) |> Mounts.scratch()
    log_dir = Path.join(scratch, @log_subdir)
    log_path = Path.join(log_dir, "#{job_id}.log")

    sandbox_log_path =
      Path.join([Sandbox.sandbox_tmp_path(scratch), @log_subdir, "#{job_id}.log"])

    with :ok <- File.mkdir_p(log_dir),
         :ok <- File.write(log_path, ""),
         {:ok, erl_pid, os_pid} <- run_process(attrs) do
      job = %{
        id: job_id,
        agent_key: agent_key,
        command: Map.fetch!(attrs, :command),
        script_path: Map.get(attrs, :script_path),
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
        File.rm(log_path)
        {:error, start_error(reason)}
    end
  end

  defp run_process(attrs) do
    :exec.run(
      to_charlist(Map.fetch!(attrs, :command_line)),
      exec_options(Map.get(attrs, :cd))
    )
  end

  # `{:cd, dir}` is how a backend with no chdir of its own starts the job in
  # the right directory (see `Nest.Tools.ShellCmd.exec_options/2`).
  defp exec_options(nil), do: @exec_options

  defp exec_options(dir), do: [{:cd, dir} | @exec_options]

  defp start_error(reason) when is_atom(reason), do: "Failed to start process: #{reason}"
  defp start_error({:error, reason}), do: start_error(reason)
  defp start_error(reason), do: "Failed to start process: #{inspect(reason)}"
end
