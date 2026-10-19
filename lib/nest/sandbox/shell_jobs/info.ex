defmodule Nest.Sandbox.ShellJobs.Info do
  @moduledoc """
  The wire shape of a background job: what `shell-list` shows an agent and what
  the `shell:jobs` broadcast sends the UI.

  Split out of `Nest.Sandbox.ShellJobs` (which owns the manager's state, and is
  at the source-file line cap) because this is pure shaping: no state, no
  process, nothing to get wrong. The `%Nest.Sandbox.ShellJobs.info{}` type stays
  on the manager, which is where the shape is documented.
  """

  @doc """
  One job as the wire shape.

  `log_path` is the path the *sandbox* sees, not the log file the manager writes:
  it is what the agent is told and what the UI renders. `Map.get` rather than
  `job.sandbox_log_path` so a job already in a live manager's state from before
  that field existed still renders.
  """
  @spec to_info(map()) :: Nest.Sandbox.ShellJobs.info()
  def to_info(job) do
    %{
      id: job.id,
      command: job.command,
      status: if(job.status == :running, do: :running, else: :exited),
      exit_code: job.exit_code,
      killed: job.killed,
      log_path: Map.get(job, :sandbox_log_path, job.log_path),
      started_at: job.started_at
    }
  end

  @doc """
  A job's status, as `shell-wait`/`shell-status` report it.
  """
  @spec status(map()) :: :running | {:exited, integer()}
  def status(%{status: :running}), do: :running
  def status(%{status: {:exited, code}}), do: {:exited, code}
end
