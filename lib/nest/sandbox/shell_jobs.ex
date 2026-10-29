defmodule Nest.Sandbox.ShellJobs do
  @moduledoc """
  Per-agent manager for shell jobs.

  A `shell-cmd` call with `background: true` hands its sandbox command to
  this manager instead of waiting for it. The manager owns the `:exec`
  port, streams the job's stdout/stderr to a per-job log file under the
  agent's scratch directory (`<scratch>/shell-jobs/<id>.log`), tracks its status,
  and lets `shell-list` / `shell-wait` / `shell-kill` inspect and control
  it. The sandbox is unchanged: the job is an ordinary invocation of the
  agent's backend (see `Nest.Sandbox.Backend`), so its isolation is
  identical to a foreground call. It survives only because the manager
  outlives the tool call.

  A *foreground* `shell-cmd` call is a shell job here too while it runs (issue
  #174): `Nest.Tools.ShellCmd` registers it when its command starts and finishes
  it when it ends, and the tool worker keeps the process
  (`Nest.Sandbox.ShellJobs.Owned`). So `shell-list` shows a call while it runs, a
  batch moved to the background is already listed rather than needing a
  promotion, and `shell-kill` reaches either kind. Only a background job counts
  against `caps["shell"]["background"]`.

  A job's log has two names. Under every backend whose environment is the host,
  the manager reads and writes it under the agent's scratch directory
  (`<scratch>/shell-jobs/<id>.log`), and the sandbox sees the same file at
  `/tmp/<agent-name>/shell-jobs/<id>.log`, because the *space* scratch dir is
  bound at `/tmp` inside it and the agent's own dir is `<agent-name>` beneath
  that. Under `"docker"` there is only one name, and it is a *container* path:
  the scratch is the container's own `/tmp`, so the command writes the log
  itself and the manager reads it through the container — see
  `Nest.Sandbox.ShellJobs.JobLog`, which is the whole of that difference.

  Everything an agent is told — the "started" message, `shell-list`, the
  `shell:jobs` broadcast — uses the sandbox path, since that is the only one that
  resolves inside a `shell-cmd`. A scratch-directory path handed to an agent is
  unusable (and leaks the harness's layout).

  ## Limits and lifetime

  At most `caps["shell"]["background"]` *background* jobs (default 1) may run
  concurrently per agent; `0` disables background jobs. The cap is per agent
  and stays that way. Jobs are keyed by `{space_id, agent_name}` and die when
  their agent dies — the manager monitors the agent pid and drops the agent's
  jobs on its `:DOWN` — or when a caller invokes `stop_all/1`/
  `stop_all_async/2`. A drop also removes the agent's scratch directory, after
  the jobs are stopped. Finished jobs are kept (bounded) so `shell-wait` can
  still answer for one — `shell-list` lists only what is running (#181).

  Listing and killing are the two space-scoped operations: `list_space/1` and
  `kill_space/2` reach every job belonging to any agent in one space, so a
  parent agent can find and stop a job a sibling left holding locks. Nothing
  else crosses agents — `status/2`, `output/2`, `subscribe/3` and `kill/2` are
  owner-scoped, and no operation reaches a job in another space.

  ## Events

  When an agent topic is known, every change to an agent's jobs — a start, an
  exit, a kill, a trim, or the whole set being dropped with its agent —
  broadcasts `{:shell_jobs, %{jobs: [...]}}` on `"agent:<space_id>:<name>"` for
  the job panel, and `{:agent_jobs, %{space_id, name, count}}` on the space's
  topic for the sidebar's agent row (#175). `Frames` builds both.

  ## Blocking

  This GenServer never blocks for an unknown amount of time. Every
  callback does bounded, local work: `:exec.run`/`:exec.kill` are
  synchronous OS calls, and the only file I/O is the job log — `File.write` of
  a streamed chunk, `File.read` of the log (proportional to that log's size;
  logs are not capped on disk by design), and the `File.rm_rf` of a dropped
  agent's scratch directory. Under `"docker"` those three are one `docker exec`
  (the read, bounded like the `File.read` it replaces), a no-op (the command
  writes its own log), and a no-op (the scratch is the container's). It never
  waits on an agent, an LLM, or another process, so a `GenServer.call/3` to it
  is ordinary synchronous communication, not a blocking hand-off.

  The `rm_rf` is the one cost this process carries that scales with the
  agent's own data (the uncapped logs under its scratch). It stays here
  rather than moving to a task: the removal's whole point is that it is
  ordered *after* the job kills, so it must run in the process that did
  the killing, and a task spawned from here could outlive the manager.
  The work is bounded by one agent's scratch and runs on a path (the
  agent going away) where the manager has nothing else queued for it.
  """

  use GenServer

  alias Nest.Sandbox.ShellJobs.{Agents, ExitNotice, Frames, Index, Info, JobLog, Launcher}
  alias Nest.Sandbox.ShellJobs.{Owned, Records, Text, Waiters}
  alias Nest.Tools.ShellCmd

  @name __MODULE__
  @default_max_jobs 1
  # How long after a kill to force a terminal state if the exec port's
  # DOWN never arrives (SIGKILL + monitor should make it prompt).
  @kill_finalize_ms 5_000

  @type job_id :: String.t()
  @type agent_key :: {term(), term()}

  # ---- Client API ----

  @doc "The registered name this GenServer runs under."
  @spec name() :: atom()
  def name, do: @name

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{id: @name, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc """
  Start a background job.

  Attrs:

    * `:agent_key` — `{space_id, agent_name}`, the ownership key
    * `:agent_pid` — monitored; all the agent's jobs die with it
    * `:command` — the original command (for display)
    * `:caps` — the mode's caps, which the backend needs to build the job's
      command line (`Nest.Sandbox.Backend.job_spec/4`)
    * `:script_sandbox` — the staged script's spelling *inside* the
      environment, which is what the command line hands the shell
    * `:script_path` — the staged script's host path, removed once
      the job ends
    * `:mounts` — the `Nest.Sandbox.Mounts` value for the agent; the log
      lives under its scratch directory (which the sandbox sees at
      `/tmp/<agent-name>`), and its backend is what decides where that
      scratch directory is when the agent is dropped
    * `:max_jobs` — the per-agent ceiling (default #{@default_max_jobs})
    * `:waiter` — the pid to register for `{:shell_job_exit, job_id, code}`
      (default: the caller). Registered in the same callback that creates the
      job, so a job cannot be observed to exit before its waiter exists —
      `waiter: nil` opts out, for a job nobody waits on (the case the owner
      notice, issue #163, exists for)

  Returns `{:ok, job_id, log_path}`, where `log_path` is the path inside
  the sandbox, or `{:error, reason}`.
  """
  @spec start_job(map()) :: {:ok, job_id(), String.t()} | {:error, String.t()}
  def start_job(attrs) do
    GenServer.call(@name, {:start_job, attrs}, 30_000)
  end

  @doc """
  Register a foreground `shell-cmd` call as a shell job for its duration (#174).

  `attrs` carries `:agent_key`, `:agent_pid`, `:command`, `:mounts` and `:os_pid`.
  The caller becomes the job's owner: it keeps the `:exec` process, appends the
  job's output and finishes it, and a kill reaches it as a `{:kill_job, id}`
  message. Returns `{:ok, job}` — the record the worker appends through and
  finishes — or `{:error, reason}` when no log can be prepared; a call that
  cannot register still runs.
  """
  @spec register_owned(map()) :: {:ok, map()} | {:error, String.t()}
  def register_owned(attrs), do: GenServer.call(@name, {:register_owned, attrs}, 30_000)

  @doc """
  Finish the foreground call's job `job_id` with `code`, from its owner.

  Called on every terminal path — exit, timeout, Stop, kill and cancellation — so
  a job never outlives its call. It delivers no `ExitNotice`: the call's own
  result is the agent's report.
  """
  @spec finish_owned(job_id(), integer()) :: :ok
  def finish_owned(job_id, code), do: GenServer.call(@name, {:finish_owned, job_id, code})

  @doc """
  Metadata for every job belonging to `agent_key`: running first, then finished,
  each newest first (`Nest.Sandbox.ShellJobs.Info.list/2`).
  """
  @spec list(agent_key()) :: [Info.t()]
  def list(agent_key), do: GenServer.call(@name, {:list, agent_key})

  @doc """
  Metadata for every job belonging to any agent in `space_id`, ordered like
  `list/1` — the space-wide listing `shell-list scope: "space"` renders, so an
  agent can see a job a sibling agent left running instead of only its own.
  """
  @spec list_space(term()) :: [Info.t()]
  def list_space(space_id), do: GenServer.call(@name, {:list_space, space_id})

  @doc """
  The number of *running* jobs per agent name in `space_id` (#175) — what the
  sidebar shows after each agent's name, and `0` for a name it does not mention.

  One call per space rather than one per agent: the lobby's `init` annotates
  every row of a space at once. Finished jobs are kept for `shell-wait`, so
  they are not live and do not count.
  """
  @spec running_counts(term()) :: %{String.t() => non_neg_integer()}
  def running_counts(space_id), do: space_id |> list_space() |> Info.running_counts()

  @doc "The status of a single job."
  @spec status(agent_key(), job_id()) ::
          {:ok, :running | {:exited, integer()}} | {:error, :not_found}
  def status(agent_key, job_id), do: GenServer.call(@name, {:status, agent_key, job_id})

  @doc """
  The job's captured output (the full log file), or `{:ok, ""}` when the
  log is missing.
  """
  @spec output(agent_key(), job_id()) :: {:ok, binary()} | {:error, :not_found}
  def output(agent_key, job_id), do: GenServer.call(@name, {:output, agent_key, job_id})

  @doc """
  Register `pid` to receive `{:shell_job_exit, job_id, exit_code}`. When
  the job has already exited, the message is sent immediately.
  """
  @spec subscribe(agent_key(), job_id(), pid()) :: :ok | {:error, :not_found}
  def subscribe(agent_key, job_id, pid),
    do: GenServer.call(@name, {:subscribe, agent_key, job_id, pid})

  @doc """
  Remove `pid` from `job_id`'s waiter list and answer with the job's state at
  the removal. Used when a caller abandons a wait (a timeout, `:stop_chat`), so
  a later exit doesn't send it a stray `{:shell_job_exit, ...}` message.
  Idempotent.

  The state is the point of the reply, not a courtesy. A caller that gave up
  waiting cannot tell whether the exit landed in the window between its own
  timeout firing and this call being handled: the exit's
  `{:shell_job_exit, ...}` would arrive after it stopped listening, and the
  owner notice is suppressed because it *was* registered. One answer, from the
  process that owns the ordering, is what stops that exit being lost.

  `:gone` and `:trimmed` are both a job the manager no longer tracks, and a
  waiter can outlive either, since a `shell-wait` watcher and a tool worker are
  siblings of the agent supervisor rather than children of the agent: `:gone` is
  a job dropped with its agent, `:trimmed` one evicted by retention after it
  exited (only its exit code went with the record).
  """
  @spec unsubscribe(agent_key(), job_id(), pid()) ::
          :running | {:exited, integer()} | :trimmed | :gone
  def unsubscribe(agent_key, job_id, pid),
    do: GenServer.call(@name, {:unsubscribe, agent_key, job_id, pid})

  @doc """
  The pids registered as waiters for `job_id`, in registration order (newest
  first).

  Test-only introspection: the manager owns the waiter list, and a test that
  asserts "this caller is not left registered" needs to read it rather than
  race an OS kill against a fixed receive timeout.

  `timeout` is the `GenServer.call/3` failure bound; the default is OTP's
  (5 s). A converted test site passes the suite's 1 s bound instead.
  """
  @spec waiters(job_id(), timeout()) :: [pid()]
  def waiters(job_id, timeout \\ 5_000), do: GenServer.call(@name, {:waiters, job_id}, timeout)

  @doc """
  Kill a running job. Its exit code is reported once the process dies.

  The owner asked, so its exit is **not** reported back as a notice (issue
  #163): this call already answers with it. A sibling's `kill_space/2` is not
  the owner's request and still notifies.
  """
  @spec kill(agent_key(), job_id()) :: :ok | {:error, :not_found}
  def kill(agent_key, job_id), do: GenServer.call(@name, {:kill, agent_key, job_id})

  @doc """
  Kill a running job owned by *any* agent in `space_id`, answering with the
  owner's `agent_key` so the caller can say whose job it stopped.

  The lookup and the kill happen in the same callback, so a job that exits in
  between cannot be reported as killed from a stale read. `{:error, :not_found}`
  is a job that belongs to another space, or to nothing.

  The owner is told the job exited (issue #163) — it did not ask for this, so
  the job is one it did not mean to lose — unless it is waiting on it
  (`shell-wait`).
  """
  @spec kill_space(term(), job_id()) :: {:ok, agent_key()} | {:error, :not_found}
  def kill_space(space_id, job_id),
    do: GenServer.call(@name, {:kill_space, space_id, job_id})

  @doc """
  Stop every job for `agent_key` synchronously, then remove the agent's scratch
  directory (see `drop_agent/3`).

  **Narrowed contract:** this form names no incarnation — it passes `owner:
  nil` — so the removal refuses while *any* live agent is registered under the
  key (`Nest.Agents.Agent.TmpSpace.cleanup_agent_key/2`). It is the
  administrative/test form; its callers in this tree are the shell-jobs tests.
  An agent's own `terminate/2` uses `stop_all_async/2`, which carries `self()`
  and so may remove the scratch its own incarnation owns.
  """
  @spec stop_all(agent_key()) :: :ok
  def stop_all(agent_key), do: GenServer.call(@name, {:stop_all, agent_key}, 10_000)

  @doc """
  Stop every running job for `agent_key`, keeping its key, job history and scratch.

  The space edit's quiesce (`Nest.Spaces.update_environment/2`): the job is work in
  the environment about to change, but the agent is not going away, so `stop_all/1`
  (which drops the key and removes the scratch) is the wrong tool.
  """
  @spec stop_jobs(agent_key()) :: :ok
  def stop_jobs(agent_key), do: GenServer.call(@name, {:stop_jobs, agent_key}, 10_000)

  @doc """
  Ask the manager to stop every job belonging to `agent_key`, without waiting
  for it to happen. `owner` is the agent's pid — the incarnation the stop is
  for; see `Nest.Agents.Agent.TmpSpace.cleanup_agent_key/2` for why it travels
  with the request.

  The non-blocking form of `stop_all/1`, for `Nest.Agents.Agent.terminate/2`:
  the manager is a process-global rendezvous that every agent's teardown passes
  through, so a synchronous stop there puts a shared process's queue latency
  inside every agent's exit — the same rendezvous that can leave a *dying*
  agent unable to answer a call for hundreds of milliseconds. A cast returns
  immediately; the manager still stops the jobs and removes the scratch, and it
  already monitors the agent pid (`track_agent/3`), so they die with the agent.
  """
  @spec stop_all_async(agent_key(), pid()) :: :ok
  def stop_all_async(agent_key, owner), do: GenServer.cast(@name, {:stop_all, agent_key, owner})

  @doc """
  Whether any *running* job belongs to space `space_id` — the question
  `Nest.Agents.TmpSweeper` asks before removing a space's scratch directory.

  Finished jobs are kept for `shell-wait`, so they are not live and do not
  count; `false` when nothing is tracked. A foreground `shell-cmd` is a job
  too while it runs (#174), so a call in flight keeps its space live — which is
  what its own scratch directory needs.
  """
  @spec live_in_space?(integer()) :: boolean()
  def live_in_space?(space_id), do: GenServer.call(@name, {:live_in_space?, space_id})

  # The sentences this manager says live in `Text`, so the three places a job's
  # exit is reported — `shell-wait`'s inline answer, the watcher's message, and
  # the owner's notice — cannot drift.
  defdelegate result_text(id, code, output), to: Text
  defdelegate gone_text(id), to: Text
  defdelegate trimmed_text(id), to: Text

  # ---- Server callbacks ----

  @impl true
  def init(_) do
    {:ok, %{jobs: %{}, agents: %{}, waiters: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_job, attrs}, {caller, _ref}, state) do
    agent_key = Map.fetch!(attrs, :agent_key)
    max_jobs = Map.get(attrs, :max_jobs, @default_max_jobs)

    case start_guarded(attrs, agent_key, max_jobs, state) do
      {:ok, job_id, log_path, state} ->
        waiter = Map.get(attrs, :waiter, caller)
        state = Agents.track(state, agent_key, attrs)

        state =
          if is_pid(waiter),
            do: %{state | waiters: Waiters.add(state.waiters, job_id, waiter)},
            else: state

        {:reply, {:ok, job_id, log_path}, Frames.broadcast(state, agent_key)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_owned, attrs}, {owner, _ref}, state) do
    case Owned.new(attrs, "job-#{state.next_id}", owner) do
      {:ok, job} ->
        state = state |> Agents.track(Map.fetch!(attrs, :agent_key), attrs) |> Records.put(job)
        {:reply, {:ok, job}, Frames.broadcast(state, job.agent_key)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish_owned, job_id, code}, _from, state),
    do: {:reply, :ok, Owned.finish(state, job_id, code)}

  def handle_call({:list, agent_key}, _from, state),
    do: {:reply, Info.list(state.jobs, &(&1.agent_key == agent_key)), state}

  def handle_call({:list_space, space_id}, _from, state),
    do: {:reply, Info.list(state.jobs, &match?({^space_id, _}, &1.agent_key)), state}

  def handle_call({:status, agent_key, job_id}, _from, state) do
    case Index.fetch(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, Info.status(job)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:output, agent_key, job_id}, _from, state) do
    case Index.fetch(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, JobLog.read(job.mounts, job.log_path)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:subscribe, agent_key, job_id, pid}, _from, state) do
    case Index.fetch(state, agent_key, job_id) do
      {:ok, %{status: {:exited, code}}} ->
        send(pid, {:shell_job_exit, job_id, code})
        {:reply, :ok, state}

      {:ok, _running} ->
        {:reply, :ok, %{state | waiters: Waiters.add(state.waiters, job_id, pid)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, agent_key, job_id, pid}, _from, state) do
    state = %{state | waiters: Waiters.remove(state.waiters, job_id, pid)}
    {:reply, Index.state(state, agent_key, job_id), state}
  end

  def handle_call({:waiters, job_id}, _from, state) do
    {:reply, Waiters.get(state.waiters, job_id), state}
  end

  def handle_call({:live_in_space?, space_id}, _from, state) do
    live? =
      Enum.any?(state.jobs, &match?({_id, %{status: :running, agent_key: {^space_id, _}}}, &1))

    {:reply, live?, state}
  end

  def handle_call({:kill, agent_key, job_id}, _from, state) do
    case Index.fetch(state, agent_key, job_id) do
      {:ok, job} -> {:reply, :ok, kill_job(job, state, :owner)}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:kill_space, space_id, job_id}, _from, state) do
    case Index.fetch_in_space(state, space_id, job_id) do
      {:ok, job} -> {:reply, {:ok, job.agent_key}, kill_job(job, state, :space)}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop_jobs, agent_key}, _from, state),
    do: {:reply, :ok, Agents.stop_running(agent_key, state)}

  def handle_call({:stop_all, agent_key}, _from, state) do
    # No incarnation to name: the sync form is a caller that only wants the
    # jobs gone (in this tree, the shell-jobs tests), so any live owner of the
    # key refuses the scratch removal. See `TmpSpace.cleanup_agent_key/2`.
    {:reply, :ok, Agents.drop(agent_key, state, nil)}
  end

  @impl true
  def handle_cast({:stop_all, agent_key, owner}, state) do
    {:noreply, Agents.drop(agent_key, state, owner)}
  end

  @impl true
  def handle_info({stream, os_pid, data}, state) when stream in [:stdout, :stderr],
    do: {:noreply, Records.append_output(state, os_pid, data)}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      job = Index.by_erl_pid(state, pid) ->
        {:noreply, finish_job(job, reason, state)}

      # The tool worker behind a foreground call (#174) died mid-command, and its
      # port with it: the job is marked killed so it cannot stay `:running`.
      job = Index.by_owner_ref(state, ref) ->
        {:noreply, finish_job(%{job | killed: true}, {:killed, 137}, state)}

      agent_key = Index.agent_key_by_monitor(state, pid) ->
        {:noreply, Agents.drop(agent_key, state, pid)}

      true ->
        {:noreply, state}
    end
  end

  # Fallback terminal state for a killed job whose exec-port DOWN never
  # arrived. A no-op once the job has already finished.
  def handle_info({:kill_finalize, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      %{status: :running, killed: true} = job ->
        {:noreply, finish_job(job, {:killed, 137}, state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Killing ----

  # Kill a job and broadcast the change, remembering who asked: the owner's own
  # `shell-kill` is not reported back as a notice, a sibling's kill is
  # (issue #163, `ExitNotice`). A job that already exited is a no-op that still
  # reports success, so a repeated kill is harmless.
  defp kill_job(%{status: :running} = job, state, by) do
    Agents.request_stop(job)

    # The exec port should send a DOWN that finishes the job. If it never
    # arrives, `@kill_finalize_ms` later forces a terminal state so the job
    # can't be stuck "running, killed" forever. For a foreground call that is
    # also the fallback for an owner that never answers its `{:kill_job, id}`.
    Process.send_after(self(), {:kill_finalize, job.id}, @kill_finalize_ms)

    state
    |> Records.put(%{job | killed: true, killed_by: by})
    |> Frames.broadcast(job.agent_key)
  end

  defp kill_job(_exited, state, _by), do: state

  # ---- Start / cap enforcement ----

  defp start_guarded(attrs, agent_key, max_jobs, state) do
    cond do
      max_jobs <= 0 ->
        {:error, Text.background_disabled()}

      Index.running_count(state, agent_key) >= max_jobs ->
        {:error, Text.cap_reached(max_jobs)}

      true ->
        job_id = "job-#{state.next_id}"

        case Launcher.launch(attrs, agent_key, job_id) do
          {:ok, job, log_path} -> {:ok, job_id, log_path, Records.put(state, job)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ---- Output / completion ----

  defp finish_job(job, reason, state) do
    code = exit_code(reason)

    # Before the waiters are told and forgotten: the notice is suppressed for a
    # job someone is waiting on, so it has to read the waiter list as it was at
    # the exit (issue #163). A job with an `owner` is a foreground call (#174),
    # whose own result is already the agent's report — a notice would be a second
    # turn on the same call.
    unless job.owner, do: ExitNotice.deliver(job, code, state)

    state =
      state
      |> Map.update!(:waiters, &Waiters.notify_exit(&1, job.id, code))
      |> Records.put(%{job | status: {:exited, code}, exit_code: code})
      |> Records.trim(job.agent_key)

    Records.remove_script(job)
    Frames.broadcast(state, job.agent_key)
  end

  defp exit_code(:normal), do: 0
  defp exit_code({:killed, code}), do: code
  defp exit_code(reason), do: ShellCmd.exit_code(reason)
end
