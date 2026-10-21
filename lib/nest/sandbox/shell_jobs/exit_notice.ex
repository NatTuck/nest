defmodule Nest.Sandbox.ShellJobs.ExitNotice do
  @moduledoc """
  The owner's notice that a background job exited (issue #163).

  `Nest.Sandbox.ShellJobs.finish_job/3` is a job's single exit point: it tells
  the job's waiters (`Waiters.notify_exit/3`) and broadcasts the new job list
  for the UI. Neither reaches the agent that *started* the job, so an agent
  that did not `shell-wait` was never told its job had ended. This module is
  that missing notification.

  The agent is told by a **cast** (`Nest.Agents.Agent.shell_job_exited/4`): the
  manager never blocks on an agent to finish a job. The notice is
  `Nest.Agents.Agent.ShellJobNotice`'s wording, enqueued as a `:runtime` entry
  and drained when the agent is idle, so an idle agent takes a turn on it.

  ## When the owner is not told

    * **A waiter is registered at exit time.** A `shell-wait` *is* the agent
      asking to be told, and `subscribe/3` answers a waiter that arrives after
      the exit, so suppressing the notice loses nothing.
    * **The owner asked for the kill.** `ShellJobs.kill/2` is the agent's own
      `shell-kill`, whose tool result already reports the exit; a second notice
      would be noise. A kill from a *sibling* (`kill_space/2`) did not ask, so
      it still notifies — that is exactly the job the owner did not mean to
      lose. `job.killed_by` is which of the two it was.
    * **The agent is going away.** A drop (`drop_agent/3`, reached from
      `stop_all/1`, `stop_all_async/2` and the agent's own `:DOWN`) stops the
      jobs and forgets them in one callback, so the `:DOWN` that would have
      finished a job finds no job at all and never reaches `finish_job/3`. The
      owner lookup here would find no pid either.

  Split out of `Nest.Sandbox.ShellJobs` for the file cap, like `Waiters`: the
  manager owns the state, this module owns one notification out of it, and it
  reads that state the way `Index` does.
  """

  alias Nest.Agents.Agent
  alias Nest.Sandbox.ShellJobs.{JobLog, Waiters}

  @doc """
  Tell `job`'s owner that it exited with `code`, unless it is already being told
  or it asked for the kill. `state` is the manager's, read the way `Index`
  reads it.

  A cast, so a dead or wedged agent cannot hold up the job's exit.
  """
  @spec deliver(map(), integer(), map()) :: :ok
  def deliver(job, code, state) do
    owner = owner_pid(job, state)

    if is_pid(owner) and not asked?(job, state) do
      Agent.shell_job_exited(owner, job.id, code, JobLog.read(job.mounts, job.log_path))
    end

    :ok
  end

  # The owner asked to be told by another route: a `shell-wait` waiter, or its
  # own `shell-kill`.
  defp asked?(job, state) do
    Map.get(job, :killed_by) == :owner or Waiters.get(state.waiters, job.id) != []
  end

  # The owning agent's pid, or `nil` for a job whose key names no agent (the
  # tools' `{:unknown, :unknown}` fallback) or whose agent is not tracked.
  defp owner_pid(job, state) do
    case Map.get(state.agents, job.agent_key) do
      %{pid: pid} -> pid
      _untracked -> nil
    end
  end
end
