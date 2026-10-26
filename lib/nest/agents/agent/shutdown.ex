defmodule Nest.Agents.Agent.Shutdown do
  @moduledoc """
  What an agent does when it stops: the steps of `Nest.Agents.Agent.terminate/2`,
  in the order they have to happen.

  Split out of `Nest.Agents.Agent` for the source-file cap, and because the
  ordering is the whole subject: every step here is a fence something else
  relies on, and none of them can be reordered without breaking one.

  ## The ordering, and why

    * **Workers first** (`stop_workers/1`). They are Tasks under the
      application-wide `Nest.Agents.TaskSupervisor`, not children of this
      process, so nothing else reaches them: `SubAgent.cascade_terminate/1` stops
      children and watchers, and the shell-jobs cast stops jobs. A worker left
      running past this process keeps doing the turn's work with nothing left to
      consume it.
    * **Then the shell jobs**, as a cast. Deliberately non-blocking: the manager
      is a process-global rendezvous that every agent's teardown passes through,
      so waiting on it here would put a shared process's queue latency inside
      every agent's exit. The manager already monitors this pid, so the cast is
      not what keeps a job from outliving its agent.
    * **Then the scratch directory**, which is the *fence* the tmp-path tests
      rely on: the directory is gone by the time this process's `:DOWN` arrives.
      It is not the ordering guarantee against a running job — the cast above can
      still be processed after this line; that guarantee is the manager's, in
      `Nest.Sandbox.ShellJobs.Agents.drop/3`, which removes the same directory
      *after* it has stopped the agent's jobs.
    * **Then the stop frame** (#73), before the process goes away, so a peer
      session learns that it stopped instead of inferring it from a status that
      will never change again. This callback is the only place that knows the
      agent has *actually* stopped, and every death path reaches it: a plain
      stop, an archive, a crash, a reload.
    * **Then the registry name**, last. Releasing it earlier would let a
      replacement take the name while this process is still stopping workers and
      removing its tmp directory. See `Nest.Agents.Registry.release/2`: leaving
      it to the registry's own cleanup runs a scheduling hop after death, and
      inside that hop a start under this name is refused with an `:already_started`
      that `Supervisor.start_under_supervisor/2` reports as success — a running
      agent that does not exist.

  ## Cost

  This runs inside the exit handshake the test teardown uses as its idle detector
  (`Nest.Agents.AgentTestLifecycle.stop_pid/2`): the test's `:DOWN` only arrives
  once it returns, so time spent here is charged to the handshake and loosens the
  detector. Keep every step local and cheap, and hand anything that is not needed
  for the process to die to the process that needs it.
  """

  alias Nest.Agents.Agent.{Broadcasts, Inbox, SubAgent, TmpSpace}
  alias Nest.Agents.Agent.Machine.{Backgrounding, Children}
  alias Nest.Agents.Registry
  alias Nest.Sandbox.{Mounts, ShellJobs}

  @doc """
  Run the shutdown for `state`, the agent's own state.

  `reason` is the exit reason `terminate/2` was given; nothing here needs it, and
  the shape is `terminate/2`'s so the callback stays a one-liner.
  """
  @spec run(term(), map()) :: :ok
  def run(_reason, state) do
    # An owed reply cannot be given up from here (the notices need a live
    # settle): it is lost with the process, so say so in the log.
    Inbox.log_lost_replies(state)

    stop_workers(state)

    # Stop any outstanding queries (children in `pending_children`) before
    # teardown. Defensive against the case where the supervisor gave up because
    # we crashed: we still want in-flight queries cut off. Idle specialists are
    # left running.
    SubAgent.cascade_terminate(state)

    ShellJobs.stop_all_async({state.space_id, state.name}, self())

    cleanup_tmp(state.mounts, state.space_id, state.name)

    # Note: workspace is preserved for review/debugging (per design)

    _ = announce_stop(state)

    # The result is ignored because a registry that is already gone is not a
    # reason for a dying agent to crash.
    _ = Registry.release(state.space_id, state.name)

    :ok
  end

  # Every worker this process's turn is running: the live one, the batches it
  # moved to the background (`Machine.Backgrounding.pids/1`), and the batch
  # coordinators (`Machine.Children.reporting_targets/1`). All are tasks under
  # the application-wide `Nest.Agents.TaskSupervisor`, not children of this
  # process, and the turn's Stop transition is the only other thing that kills
  # them — a death runs no transition. Distinct pids — one batch can be recorded
  # under two refs, and one coordinator reports for many children.
  #
  # `stop_worker/1` sends the same `{:stop_chat, self()}` handshake the
  # executor's `{:kill, pid}` action does (see `Backgrounding.kill_actions/1`):
  # it is what lets a worker parked in a foreground `shell-cmd` `:exec.stop/1`
  # its bwrap process before it goes. Without it the signal kills the worker
  # while its sandbox process is still running. No wait: this runs inside the
  # exit handshake.
  defp stop_workers(state) do
    machine = state.live.machine

    ([machine.work.active_worker | Backgrounding.pids(machine)] ++
       Children.reporting_targets(machine.children))
    |> Enum.uniq()
    |> Enum.each(&stop_worker/1)
  end

  defp stop_worker(pid) when is_pid(pid) do
    send(pid, {:stop_chat, self()})
    Process.exit(pid, :shutdown)
  end

  defp stop_worker(_none), do: :ok

  # Clean up this agent's own tmp sub-directory. Never touches the space
  # directory or a sibling's files. Delegates to
  # `Nest.Agents.Agent.TmpSpace.cleanup/3` so this module doesn't carry the
  # boilerplate; the backend comes from the agent's own mounts, because it
  # decides which root the scratch directory is under.
  defp cleanup_tmp(%Mounts{} = mounts, space_id, agent_name),
    do: TmpSpace.cleanup(space_id, agent_name, Mounts.backend(mounts))

  # Announce this agent's stop from inside the exit handshake (#73), tolerating a
  # PubSub that is already gone: an application shutdown stops every agent, and a
  # dying agent must not crash over it — the same reason `Registry.release/2`
  # reports its own failure instead of raising.
  defp announce_stop(state) do
    Broadcasts.agent_stopped(state.space_id, %{
      "space_id" => state.space_id,
      "name" => state.name
    })
  rescue
    ArgumentError -> :error
  end
end
