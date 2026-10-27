defmodule Nest.Tools.ShellCmd.Background do
  @moduledoc """
  The background half of a `shell-cmd` call.

  `Nest.Tools.ShellCmd` decides *whether* a call is backgrounded and builds its
  command line; this module runs it as a job: hand the command to
  `Nest.Sandbox.ShellJobs`, report one that exits within the grace window as an
  ordinary result, and otherwise answer with the job handle. Split out of
  `Nest.Tools.ShellCmd` for the source-file cap.

  The command line is the *launcher's* to build rather than this module's: a
  job's output also has to reach its log file inside the environment, and for the
  docker backend that means the command itself writes it — which needs the log
  path, which the manager allocates. So the manager is handed what the backend
  needs (`caps` and the script's sandbox spelling) and asks for a job spec
  (`Nest.Sandbox.Backend.job_spec/4`).

  A background job is a job from the moment it is registered, so this path adds
  no job record of its own; a *foreground* call registers through
  `Nest.Sandbox.ShellJobs.Owned` instead.
  """

  require Logger

  alias Nest.Sandbox.{Mounts, ShellJobs}
  alias Nest.Tools.ShellCmd.{Diagnostics, Result}

  @default_grace_ms 200

  @doc """
  Start `command` as a background job and either report an immediate exit as a
  normal result or hand the caller a job handle.

  `script` is the staged transcript's host path — `ShellJobs` removes it when the
  job ends, and this removes it when the job never starts. `script_sandbox` is
  the spelling the backend's command line hands bash, and `opts` carries
  `:agent_key`, `:agent_pid` and `:grace_ms`.
  """
  @spec run(String.t(), String.t(), String.t(), Mounts.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(command, script, script_sandbox, mounts, caps, opts) do
    if is_nil(Mounts.scratch(mounts)) do
      File.rm(script)
      {:error, "Background jobs require a tmp directory"}
    else
      grace = Keyword.get(opts, :grace_ms, @default_grace_ms)
      agent_key = Keyword.get(opts, :agent_key, {:unknown, :unknown})

      Logger.info(
        "Starting background shell job in #{Mounts.workspace(mounts) || "/"}: " <>
          Diagnostics.truncate(command)
      )

      case ShellJobs.start_job(%{
             agent_key: agent_key,
             agent_pid: Keyword.get(opts, :agent_pid),
             command: command,
             caps: caps,
             script_sandbox: script_sandbox,
             script_path: script,
             mounts: mounts,
             max_jobs: cap(caps)
           }) do
        {:ok, job_id, log_path} ->
          await_start(job_id, log_path, grace, agent_key, command, mounts)

        {:error, reason} ->
          File.rm(script)
          {:error, reason}
      end
    end
  end

  defp await_start(job_id, log_path, grace, agent_key, command, mounts) do
    # No `subscribe/3`: `start_job/1` already registered this process, in the
    # callback that created the job — subscribing here was the window that
    # reported one exit twice, inline and as the owner's notice.
    receive do
      {:shell_job_exit, ^job_id, code} ->
        {:ok, output} = ShellJobs.output(agent_key, job_id)
        Result.from_exit(command, code, output, mounts)
    after
      grace ->
        # The exit may have been handled between the timeout above and this
        # call, in which case its message arrives after we stopped listening and
        # the notice was suppressed because we *were* registered. The reply is
        # the state at the removal, so that window has one answer rather than
        # none.
        case ShellJobs.unsubscribe(agent_key, job_id, self()) do
          :running ->
            {:ok,
             "Started background job #{job_id} (log: #{log_path}). " <>
               "Use shell-list, shell-wait, or shell-kill to manage it."}

          {:exited, code} ->
            {:ok, output} = ShellJobs.output(agent_key, job_id)
            Result.from_exit(command, code, output, mounts)

          :gone ->
            {:ok, ShellJobs.gone_text(job_id)}

          :trimmed ->
            {:ok, ShellJobs.trimmed_text(job_id)}
        end
    end
  end

  # The per-agent background-job ceiling: `caps.shell.background` when set,
  # otherwise the always-on default of 1.
  defp cap(nil), do: 1

  defp cap(caps) do
    case get_in(caps, ["shell", "background"]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 1
    end
  end
end
