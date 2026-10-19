defmodule Nest.Sandbox.ShellJobs do
  @moduledoc """
  Per-agent manager for background shell jobs.

  A `shell-cmd` call with `background: true` hands its sandbox command to
  this manager instead of waiting for it. The manager owns the `:exec`
  port, streams the job's stdout/stderr to a per-job log file under the
  agent's scratch directory (`<scratch>/shell-jobs/<id>.log`), tracks its status,
  and lets `shell-list` / `shell-wait` / `shell-kill` inspect and control
  it. The sandbox is unchanged: the job is an ordinary invocation of the
  agent's backend (see `Nest.Sandbox.Backend`), so its isolation is
  identical to a foreground call. It survives only because the manager
  outlives the tool call.

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

  At most `caps["shell"]["background"]` jobs (default 1) may run
  concurrently per agent; `0` disables background jobs. Jobs are keyed
  by `{space_id, agent_name}` and die when their agent dies — the manager
  monitors the agent pid and drops the agent's jobs on its `:DOWN` — or
  when a caller invokes `stop_all/1`/`stop_all_async/2`. A drop also removes
  the agent's scratch directory, after the jobs are stopped. Finished jobs
  are kept (bounded) for `shell-wait`/`shell-list`.

  ## Events

  When an agent topic is known, the manager broadcasts
  `{:shell_jobs, %{jobs: [...]}}` on `"agent:<space_id>:<name>"` when a
  job starts, exits, or is killed, so the UI can render the running set.

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

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.PubSub
  alias Nest.Sandbox.{Backend, Mounts}
  alias Nest.Sandbox.ShellJobs.{Info, JobLog, Launcher}
  alias Nest.Sandbox.ShellJobs.Waiters
  alias Nest.Tools.ShellCmd

  @name __MODULE__
  @default_max_jobs 1
  @max_finished_per_agent 50
  # How long after a kill to force a terminal state if the exec port's
  # DOWN never arrives (SIGKILL + monitor should make it prompt).
  @kill_finalize_ms 5_000

  @type job_id :: String.t()
  @type agent_key :: {term(), term()}

  @type info :: %{
          id: job_id(),
          command: String.t(),
          status: :running | :exited,
          exit_code: integer() | nil,
          killed: boolean(),
          # The path inside the sandbox
          # (`/tmp/<agent-name>/shell-jobs/<id>.log`), not the log file
          # the manager writes the log to.
          log_path: String.t(),
          started_at: DateTime.t()
        }

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

  Returns `{:ok, job_id, log_path}`, where `log_path` is the path inside
  the sandbox, or `{:error, reason}`.
  """
  @spec start_job(map()) :: {:ok, job_id(), String.t()} | {:error, String.t()}
  def start_job(attrs) do
    GenServer.call(@name, {:start_job, attrs}, 30_000)
  end

  @doc "Metadata for every job belonging to `agent_key`, oldest first."
  @spec list(agent_key()) :: [info()]
  def list(agent_key), do: GenServer.call(@name, {:list, agent_key})

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
  Remove `pid` from `job_id`'s waiter list. Used when a caller abandons a
  wait (timeout or `:stop_chat`) so a later exit doesn't send it a stray
  `{:shell_job_exit, ...}` message. Idempotent.
  """
  @spec unsubscribe(agent_key(), job_id(), pid()) :: :ok
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

  @doc "Kill a running job. Its exit code is reported once the process dies."
  @spec kill(agent_key(), job_id()) :: :ok | {:error, :not_found}
  def kill(agent_key, job_id), do: GenServer.call(@name, {:kill, agent_key, job_id})

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

  Finished jobs are kept for `shell-wait`/`shell-list`, so they are not live and
  do not count; `false` when nothing is tracked. A foreground `shell-cmd` is not
  a job at all — its agent is registered while it runs.
  """
  @spec live_in_space?(integer()) :: boolean()
  def live_in_space?(space_id), do: GenServer.call(@name, {:live_in_space?, space_id})

  @doc """
  The result text for a finished job, shared by `shell-wait`'s inline answer
  (issue #54: a job that had already exited) and the watcher that delivers the
  exit as a message, so the two wordings cannot drift.
  """
  @spec result_text(job_id(), integer(), binary()) :: String.t()
  def result_text(id, 0, ""), do: "Background job #{id} exited 0 with no output."

  def result_text(id, code, output),
    do: "Background job #{id} exited with code #{code}:\n#{output}"

  @doc """
  The result text for a job whose agent stopped, delivered by the watcher
  (`Nest.Agents.Agent.Watch`) — the only place a job can be found gone.

  Deliberately not `result_text/3`'s shape: the job did not exit, it was
  dropped with its agent (`drop_agent/2`), so there is no exit code to report
  and the log may already be gone with the agent's tmp directory. Wording it as
  an exit would be a lie about what happened.
  """
  @spec gone_text(job_id()) :: String.t()
  def gone_text(id), do: "Background job #{id} is gone: the agent that owned it stopped."

  # ---- Server callbacks ----

  @impl true
  def init(_) do
    {:ok, %{jobs: %{}, agents: %{}, waiters: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start_job, attrs}, _from, state) do
    agent_key = Map.fetch!(attrs, :agent_key)
    max_jobs = Map.get(attrs, :max_jobs, @default_max_jobs)

    case start_guarded(attrs, agent_key, max_jobs, state) do
      {:ok, job_id, log_path, state} ->
        state = state |> track_agent(agent_key, attrs) |> broadcast(agent_key)
        {:reply, {:ok, job_id, log_path}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, agent_key}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == agent_key))
      # Most recent first: a listing is read to find what just ran, and a job id
      # is not a timestamp. `trim/2` sorts the other way on purpose — it deletes
      # the oldest — so the two orders are not a shared helper.
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.map(&Info.to_info/1)

    {:reply, jobs, state}
  end

  def handle_call({:status, agent_key, job_id}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, Info.status(job)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:output, agent_key, job_id}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, JobLog.read(job.mounts, job.log_path)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:subscribe, agent_key, job_id, pid}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, %{status: {:exited, code}}} ->
        send(pid, {:shell_job_exit, job_id, code})
        {:reply, :ok, state}

      {:ok, _running} ->
        {:reply, :ok, %{state | waiters: Waiters.add(state.waiters, job_id, pid)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, _agent_key, job_id, pid}, _from, state) do
    {:reply, :ok, %{state | waiters: Waiters.remove(state.waiters, job_id, pid)}}
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
    case fetch_job(state, agent_key, job_id) do
      {:ok, %{status: :running} = job} ->
        stop_os_process(job)

        # The exec port should send a DOWN that finishes the job. If it
        # never arrives, `@kill_finalize_ms` later forces a terminal
        # state so the job can't be stuck "running, killed" forever.
        Process.send_after(self(), {:kill_finalize, job_id}, @kill_finalize_ms)

        state =
          state
          |> put_job(%{job | killed: true})
          |> broadcast(agent_key)

        {:reply, :ok, state}

      {:ok, _exited} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:stop_jobs, agent_key}, _from, state),
    do: {:reply, :ok, stop_running_jobs(agent_key, state)}

  def handle_call({:stop_all, agent_key}, _from, state) do
    # No incarnation to name: the sync form is a caller that only wants the
    # jobs gone (in this tree, the shell-jobs tests), so any live owner of the
    # key refuses the scratch removal. See `TmpSpace.cleanup_agent_key/2`.
    {:reply, :ok, drop_agent(agent_key, state, nil)}
  end

  @impl true
  def handle_cast({:stop_all, agent_key, owner}, state) do
    {:noreply, drop_agent(agent_key, state, owner)}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, state),
    do: {:noreply, write_output(os_pid, data, state)}

  def handle_info({:stderr, os_pid, data}, state),
    do: {:noreply, write_output(os_pid, data, state)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      job = job_by_erl_pid(state, pid) ->
        {:noreply, finish_job(job, reason, state)}

      agent_key = agent_key_by_monitor(state, pid) ->
        {:noreply, drop_agent(agent_key, state, pid)}

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

  # ---- Start / cap enforcement ----

  defp start_guarded(attrs, agent_key, max_jobs, state) do
    cond do
      max_jobs <= 0 ->
        {:error, background_disabled_msg()}

      running_count(state, agent_key) >= max_jobs ->
        {:error, cap_reached_msg(max_jobs)}

      true ->
        job_id = "job-#{state.next_id}"

        case Launcher.launch(attrs, agent_key, job_id) do
          {:ok, job, log_path} -> {:ok, job_id, log_path, put_job(state, job)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ---- Output / completion ----

  defp write_output(os_pid, data, state) do
    case job_by_os_pid(state, os_pid) do
      nil ->
        state

      job ->
        JobLog.append(job.mounts, job.log_path, data)
        state
    end
  end

  defp finish_job(job, reason, state) do
    code = exit_code(reason)

    state =
      state
      |> Map.update!(:waiters, &Waiters.notify_exit(&1, job.id, code))
      |> put_job(%{job | status: {:exited, code}, exit_code: code})
      |> trim(job.agent_key)

    remove_script(job)
    broadcast(state, job.agent_key)
  end

  defp exit_code(:normal), do: 0
  defp exit_code({:killed, code}), do: code
  defp exit_code(reason), do: ShellCmd.exit_code(reason)

  # ---- Agent tracking ----

  # Monitor the agent pid the first time we see an agent, so its jobs die
  # with it, and remember the agent's `mounts` so dropping the agent knows
  # which backend's scratch directory to remove. On DOWN we drop every job
  # under the key.
  defp track_agent(state, agent_key, attrs) do
    case Map.get(state.agents, agent_key) do
      nil ->
        %{
          state
          | agents: Map.put(state.agents, agent_key, agent_record(attrs))
        }

      _existing ->
        state
    end
  end

  # A key that is already tracked keeps its first record: a space's backend is
  # fixed at creation, so a later job cannot bring a different one.
  defp agent_record(attrs) do
    pid = Map.get(attrs, :agent_pid)

    %{
      pid: pid,
      ref: monitor_agent_pid(pid),
      mounts: Map.fetch!(attrs, :mounts)
    }
  end

  defp monitor_agent_pid(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_agent_pid(_pid), do: nil

  # Stop this agent's running jobs, keeping its key, finished jobs and scratch.
  defp stop_running_jobs(agent_key, state) do
    jobs =
      for job <- Map.values(state.jobs),
          job.agent_key == agent_key and job.status == :running,
          do: job

    Enum.each(jobs, &stop_job/1)

    # A waiter that outlives the kill would wait out its timeout.
    Waiters.notify_gone(state.waiters, Enum.map(jobs, & &1.id))

    state
  end

  defp drop_agent(agent_key, state, owner) do
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

    demonitor_agent(state, agent_key)

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
    broadcast(state, agent_key)
  end

  defp stop_job(%{status: :running} = job) do
    stop_os_process(job)
    remove_script(job)
  end

  defp stop_job(job), do: remove_script(job)

  # SIGKILL the running external process. Plain `:exec.stop/1` sends
  # SIGTERM first and only escalates to SIGKILL after ~5s; bwrap (PID 1 in
  # its namespace) can ignore SIGTERM, which made kills flaky-slow. We want
  # an immediate teardown.
  defp stop_os_process(%{os_pid: os_pid}) do
    :exec.kill(os_pid, :sigkill)
  catch
    _kind, _ -> :ok
  end

  # Stop monitoring the dropped agent. A key with no record, or a record with
  # no pid (an agent the manager never saw a pid for), has no monitor to
  # cancel.
  defp demonitor_agent(state, agent_key) do
    case Map.get(state.agents, agent_key) do
      %{ref: ref} when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end
  end

  # The backend the dropped agent's jobs ran on, from the record
  # `track_agent/3` kept. An untracked key falls back to the default backend:
  # a drop with no record is a key that never started a job, and the default is
  # the only backend that can have one.
  defp tracked_backend(state, agent_key) do
    case Map.get(state.agents, agent_key) do
      %{mounts: mounts} -> Mounts.backend(mounts)
      _ -> Backend.default()
    end
  end

  # ---- Retention / cleanup ----

  # Remove the job's staged script. `script_path` is the staging path
  # `ShellCmd.stage_script/2` writes to; the spelling the backend's command line
  # uses is a different thing and must never be passed here.
  defp remove_script(%{script_path: nil}), do: :ok

  defp remove_script(%{script_path: path}) do
    File.rm(path)
    :ok
  end

  # Keep at most @max_finished_per_agent finished jobs per agent; evict
  # the oldest (deleting its log file).
  defp trim(state, agent_key) do
    finished =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == agent_key and match?({:exited, _}, &1.status)))
      |> Enum.sort_by(& &1.started_at, DateTime)

    excess = length(finished) - @max_finished_per_agent

    if excess > 0 do
      finished
      |> Enum.take(excess)
      |> Enum.reduce(state, fn job, acc ->
        JobLog.remove(job.mounts, job.log_path)
        %{acc | jobs: Map.delete(acc.jobs, job.id), waiters: Map.delete(acc.waiters, job.id)}
      end)
    else
      state
    end
  end

  # ---- Lookups / shaping ----

  defp put_job(state, job) do
    %{
      state
      | jobs: Map.put(state.jobs, job.id, job),
        next_id: max(state.next_id, id_number(job) + 1)
    }
  end

  defp id_number(%{id: "job-" <> n}), do: String.to_integer(n)

  defp fetch_job(state, agent_key, job_id) do
    case Map.get(state.jobs, job_id) do
      %{agent_key: ^agent_key} = job -> {:ok, job}
      _ -> :error
    end
  end

  defp job_by_erl_pid(state, pid),
    do: Enum.find_value(state.jobs, fn {_id, j} -> j.erl_pid == pid && j end)

  # Prefer a running job with this OS pid; fall back to a finished one so
  # trailing output still lands in its log. PID reuse across a running and
  # a retained finished job can't misroute output this way.
  defp job_by_os_pid(state, os_pid) do
    jobs = Enum.map(state.jobs, fn {_id, j} -> j end)

    Enum.find(jobs, fn j -> j.status == :running and j.os_pid == os_pid end) ||
      Enum.find(jobs, fn j -> j.os_pid == os_pid end)
  end

  defp agent_key_by_monitor(state, pid) do
    Enum.find_value(state.agents, fn {key, %{pid: p}} -> p == pid && key end)
  end

  defp running_count(state, agent_key) do
    state.jobs
    |> Map.values()
    |> Enum.count(&(&1.agent_key == agent_key and &1.status == :running))
  end

  # ---- Broadcast ----

  defp broadcast(state, {space_id, name} = agent_key)
       when is_integer(space_id) and is_binary(name) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == agent_key))
      |> Enum.map(&Info.to_info/1)

    Phoenix.PubSub.broadcast(PubSub, "agent:#{space_id}:#{name}", {:shell_jobs, %{jobs: jobs}})
    state
  end

  defp broadcast(state, _agent_key), do: state

  # ---- Messages ----

  defp background_disabled_msg do
    "Background shell jobs are disabled for this project (set `[shell] background` above 0 in .nest)."
  end

  defp cap_reached_msg(max) do
    "Background shell job limit reached (#{max} per agent). Use shell-list and shell-kill, " <>
      "or raise `[shell] background` in .nest."
  end
end
