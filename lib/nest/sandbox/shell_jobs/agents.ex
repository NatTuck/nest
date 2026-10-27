defmodule Nest.Sandbox.ShellJobs.Agents do
  @moduledoc """
  An agent's jobs, and what happens to them when the agent goes away.

  `Nest.Sandbox.ShellJobs` owns the state; this module owns the agent half of it:
  the record that tracks an agent (so its jobs die with it, and so a drop knows
  which backend's scratch directory to remove), stopping its running jobs, and
  dropping every job it has. Split out for the source-file cap, like `Index`,
  `Records` and `Owned`.

  Two stops, and the difference is deliberate:

    * `stop_running/2` is the space edit's quiesce
      (`Nest.Spaces.update_environment/2`): the work in the environment about to
      change is stopped, but the agent is not going away, so its key, its job
      history and its scratch directory all survive.
    * `drop/3` is the agent going away — its own `terminate/2`, its `:DOWN`, or
      `stop_all/1`: the jobs are stopped, their waiters are told why, and the
      scratch directory is removed after them.

  A stop reaches a job's process through whoever owns it (`request_stop/1`): the
  manager's own exec port for a background job, the tool worker for a foreground
  call (#174).
  """

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Sandbox.{Backend, Mounts}
  alias Nest.Sandbox.ShellJobs.{Frames, Records, Waiters}

  @doc """
  Monitor the agent pid the first time we see an agent, so its jobs die with it,
  and remember the agent's `mounts` so dropping the agent knows which backend's
  scratch directory to remove. On `:DOWN` the manager drops every job under the
  key.

  A key that is already tracked keeps its first record: a space's backend is
  fixed at creation, so a later job cannot bring a different one.
  """
  @spec track(map(), term(), map()) :: map()
  def track(state, agent_key, attrs) do
    case Map.get(state.agents, agent_key) do
      nil -> %{state | agents: Map.put(state.agents, agent_key, record(attrs))}
      _existing -> state
    end
  end

  @doc """
  Stop `agent_key`'s running jobs, keeping its key, its finished jobs and its
  scratch directory — the space edit's quiesce.
  """
  @spec stop_running(term(), map()) :: map()
  def stop_running(agent_key, state) do
    jobs =
      for job <- Map.values(state.jobs),
          job.agent_key == agent_key and job.status == :running,
          do: job

    Enum.each(jobs, &stop_job/1)

    # A waiter that outlives the kill would wait out its timeout.
    Waiters.notify_gone(state.waiters, Enum.map(jobs, & &1.id))

    state
  end

  @doc """
  Stop and forget every job for `agent_key`, then remove the agent's scratch
  directory.

  `owner` is the agent incarnation the drop is for (`nil` for the administrative
  form); see `Nest.Agents.Agent.TmpSpace.cleanup_agent_key/2` for why it travels.
  """
  @spec drop(term(), map(), pid() | nil) :: map()
  def drop(agent_key, state, owner) do
    jobs = state.jobs |> Map.values() |> Enum.filter(&(&1.agent_key == agent_key))
    ids = Enum.map(jobs, & &1.id)

    Enum.each(jobs, &stop_job/1)

    # Say so before the waiter lists go with the jobs: this is the only path
    # that ends a job without an exit, and a waiter that outlives its agent
    # would otherwise wait out its whole timeout and then report the job as
    # still running. See `Waiters.notify_gone/2`.
    Waiters.notify_gone(state.waiters, ids)

    # The jobs above are stopped, so the scratch directory can go now; removing
    # it first would let a running job recreate files under a deleted path.
    # `owner` is the incarnation this drop is for, so a stale monitor for a
    # previous one cannot delete the scratch a live agent is using, and the
    # backend comes from the agent's own record because a `"none"` space's
    # scratch is the host's `/tmp/<agent-name>` rather than a per-space dir.
    TmpSpace.cleanup_agent_key(agent_key, owner, tracked_backend(state, agent_key))

    demonitor(state, agent_key)

    state = %{
      state
      | jobs: Map.drop(state.jobs, ids),
        agents: Map.delete(state.agents, agent_key),
        waiters: Map.drop(state.waiters, ids)
    }

    # The agent's jobs are gone, so the frame that says so is this one: every
    # other state change broadcasts, and a client watching this agent would
    # otherwise keep rendering jobs that were just killed. A no-op for an
    # `agent_key` that is not `{space_id, name}`.
    Frames.broadcast(state, agent_key)
  end

  @doc """
  Stop a job's process and remove its staged script.

  A kill reaches the process through whoever owns it: the manager's own exec
  port for a background job, or the tool worker that owns a foreground call's
  process (#174). A plain send to that worker is right — it is a `receive` loop,
  not a GenServer.
  """
  @spec stop_job(map()) :: :ok
  def stop_job(%{status: :running} = job) do
    request_stop(job)
    Records.remove_script(job)
  end

  def stop_job(job), do: Records.remove_script(job)

  @doc """
  Ask the owner of `job`'s process to stop it, without waiting for it to happen.
  """
  @spec request_stop(map()) :: :ok
  def request_stop(%{owner: owner} = job) when is_pid(owner) do
    send(owner, {:kill_job, job.id})
    :ok
  end

  def request_stop(job), do: stop_os_process(job)

  # SIGKILL the running external process. Plain `:exec.stop/1` sends
  # SIGTERM first and only escalates to SIGKILL after ~5s; bwrap (PID 1 in
  # its namespace) can ignore SIGTERM, which made kills flaky-slow. We want
  # an immediate teardown.
  defp stop_os_process(%{os_pid: os_pid}) do
    :exec.kill(os_pid, :sigkill)
  catch
    _kind, _ -> :ok
  end

  defp record(attrs) do
    pid = Map.get(attrs, :agent_pid)

    %{pid: pid, ref: monitor_pid(pid), mounts: Map.fetch!(attrs, :mounts)}
  end

  defp monitor_pid(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_pid(_pid), do: nil

  # Stop monitoring the dropped agent. A key with no record, or a record with
  # no pid (an agent the manager never saw a pid for), has no monitor to
  # cancel.
  defp demonitor(state, agent_key) do
    case Map.get(state.agents, agent_key) do
      %{ref: ref} when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end
  end

  # The backend the dropped agent's jobs ran on, from the record `track/3` kept.
  # An untracked key falls back to the default backend: a drop with no record is
  # a key that never started a job, and the default is the only backend that can
  # have one.
  defp tracked_backend(state, agent_key) do
    case Map.get(state.agents, agent_key) do
      %{mounts: mounts} -> Mounts.backend(mounts)
      _ -> Backend.default()
    end
  end
end
