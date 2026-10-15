defmodule Nest.Sandbox.ShellJobs.Waiters do
  @moduledoc """
  The waiter list for `Nest.Sandbox.ShellJobs`: which processes are waiting on
  which background job's exit.

  Pure functions over the `waiters` map (`job_id => [pid]`, newest first). The
  manager owns the map; this module owns its shape and the two notifications the
  manager sends out of it — a job's exit, and a job dropped with its agent.
  Split out of `Nest.Sandbox.ShellJobs` for the file cap.
  """

  @type t :: %{optional(String.t()) => [pid()]}

  @doc "Register `pid` as a waiter on `job_id`."
  @spec add(t(), String.t(), pid()) :: t()
  def add(waiters, job_id, pid), do: Map.update(waiters, job_id, [pid], &[pid | &1])

  @doc "The pids waiting on `job_id`, newest first."
  @spec get(t(), String.t()) :: [pid()]
  def get(waiters, job_id), do: Map.get(waiters, job_id, [])

  @doc "Drop `pid` from `job_id`'s list. Idempotent; drops the key when empty."
  @spec remove(t(), String.t(), pid()) :: t()
  def remove(waiters, job_id, pid) do
    case Map.get(waiters, job_id) do
      nil ->
        waiters

      pids ->
        case List.delete(pids, pid) do
          [] -> Map.delete(waiters, job_id)
          remaining -> Map.put(waiters, job_id, remaining)
        end
    end
  end

  @doc "Tell every waiter on `job_id` that it exited with `code`, and forget them."
  @spec notify_exit(t(), String.t(), integer()) :: t()
  def notify_exit(waiters, job_id, code) do
    Enum.each(get(waiters, job_id), &send(&1, {:shell_job_exit, job_id, code}))
    Map.delete(waiters, job_id)
  end

  @doc """
  Tell every waiter on a dropped job that the job is gone.

  The manager's `drop_agent/3` is reached from the agent's `:DOWN` (a crash, an
  archive, a supervisor shutdown) and from `stop_all/1` / `stop_all_async/2`
  (the agent's own `terminate/2`), so the agent is always going away — but a
  waiter need not go with it. The waiter behind `shell-wait` is a watcher task
  under `Nest.Agents.TaskSupervisor`, a sibling of the agent supervisor, so it
  does not die *with* its agent: it monitors its caller and exits on that
  `:DOWN`, which races this frame. A waiter that wins the race reports what
  actually happened instead of sitting in its `receive` for the whole `timeout`
  and then claiming the job "is still running" — false twice over.

  Deliberately *not* `{:shell_job_exit, id, code}`: no exit was observed, so
  there is no code to report, and `output/2` is `:not_found` for a job the
  manager no longer tracks. The distinct tag is what lets a consumer word it as
  "the agent that owned this job is gone" rather than as a normal exit.
  """
  @spec notify_gone(t(), [String.t()]) :: :ok
  def notify_gone(waiters, job_ids) do
    Enum.each(job_ids, fn job_id ->
      Enum.each(get(waiters, job_id), &send(&1, {:shell_job_gone, job_id}))
    end)
  end
end
