defmodule Nest.Sandbox.ShellJobs.Info do
  @moduledoc """
  The wire shape of a background job: what `shell-list` shows an agent, what the
  `shell:jobs` broadcast sends the UI, and the running count the sidebar shows
  after an agent's name (#175).

  Split out of `Nest.Sandbox.ShellJobs` (which owns the manager's state, and is
  at the source-file line cap) because this is pure shaping: no state, no
  process, nothing to get wrong. The type lives here for the same reason the
  shaping does — it *is* the shape.
  """

  @typedoc """
  One job as the wire sees it.

  `agent` is the owning agent's name, so a space-wide listing can show whose job
  it is; it is `nil` for a job whose key names no agent (`{:unknown, :unknown}`,
  the tools' fallback).

  `log_path` is the path the *sandbox* sees, not the log file the manager
  writes: it is what the agent is told and what the UI renders.
  """
  @type t :: %{
          id: Nest.Sandbox.ShellJobs.job_id(),
          agent: String.t() | nil,
          command: String.t(),
          status: :running | :exited,
          exit_code: integer() | nil,
          killed: boolean(),
          log_path: String.t(),
          started_at: DateTime.t()
        }

  @doc """
  `jobs` — the manager's `id => job` map — as wire shapes, newest first, keeping
  only the jobs `owned?` accepts.

  Newest first because a listing is read to find what just ran, and a job id is
  not a timestamp. The manager's `trim/2` sorts the other way on purpose — it
  deletes the oldest — so the two orders are not a shared helper.
  """
  @spec list(%{optional(Nest.Sandbox.ShellJobs.job_id()) => map()}, (map() -> boolean())) ::
          [t()]
  def list(jobs, owned?) do
    jobs
    |> Map.values()
    |> Enum.filter(owned?)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> Enum.map(&to_info/1)
  end

  @doc """
  One job as the wire shape.

  `agent` is the owning agent's name, so a space-wide listing can show whose job
  it is; it is `nil` for a job whose key names no agent.

  `log_path` is the path the *sandbox* sees, not the log file the manager writes:
  it is what the agent is told and what the UI renders. `Map.get` rather than
  `job.sandbox_log_path` so a job already in a live manager's state from before
  that field existed still renders.
  """
  @spec to_info(map()) :: t()
  def to_info(job) do
    %{
      id: job.id,
      agent: agent_name(job),
      command: job.command,
      status: if(job.status == :running, do: :running, else: :exited),
      exit_code: job.exit_code,
      killed: job.killed,
      log_path: Map.get(job, :sandbox_log_path, job.log_path),
      started_at: job.started_at
    }
  end

  # A key that is not `{space_id, agent_name}` — the tools' `:unknown` fallback,
  # say — has no agent to name, so the field is `nil` rather than a raise.
  defp agent_name(job) do
    case Map.get(job, :agent_key) do
      {_space_id, name} when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc """
  How many of `jobs` are still running (#175).

  Finished jobs are kept for `shell-list`/`shell-wait`, so they are not live and
  do not count. This is the number the sidebar shows after an agent's name.
  """
  @spec running_count([t()]) :: non_neg_integer()
  def running_count(jobs), do: Enum.count(jobs, &(&1.status == :running))

  @doc """
  The running-job count per agent name across one space's `jobs` (#175), as the
  lobby's `init` annotates every agent row with.

  A space at a time rather than an agent at a time: `init` renders every row of
  every space it lists, and one read per space is one call to the manager
  instead of one per row. A job whose key names no agent is not any agent's and
  is left out rather than counted under `nil`.
  """
  @spec running_counts([t()]) :: %{String.t() => non_neg_integer()}
  def running_counts(jobs) do
    jobs
    |> Enum.filter(&(&1.status == :running and is_binary(&1.agent)))
    |> Enum.frequencies_by(& &1.agent)
  end

  @doc """
  A job's status, as `shell-wait`/`shell-status` report it.
  """
  @spec status(map()) :: :running | {:exited, integer()}
  def status(%{status: :running}), do: :running
  def status(%{status: {:exited, code}}), do: {:exited, code}
end
