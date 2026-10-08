defmodule Nest.Sandbox.ShellJobs do
  @moduledoc """
  Per-agent manager for background shell jobs.

  A `shell-cmd` call with `background: true` hands its bwrap command to
  this manager instead of waiting for it. The manager owns the `:exec`
  port, streams the job's stdout/stderr to a per-job log file under the
  agent's tmp dir (`<tmp_path>/shell-jobs/<id>.log`), tracks its status,
  and lets `shell-list` / `shell-wait` / `shell-kill` inspect and control
  it. The sandbox is unchanged: the job is an ordinary bwrap invocation,
  so its PID/mount/net isolation is identical to a foreground call. It
  survives only because the manager outlives the tool call.

  A job's log has two names. The manager reads and writes the host path
  (`<tmp_path>/shell-jobs/<id>.log`); the sandbox sees the same file at
  `/tmp/<agent-name>/shell-jobs/<id>.log`, because the *space* scratch
  dir is bound at `/tmp` inside it and the agent's own dir is
  `<agent-name>` beneath that. Everything an agent is told — the
  "started" message, `shell-list`, the `shell:jobs` broadcast — uses the
  sandbox path, since that is the only one that resolves inside a
  `shell-cmd`. A host path handed to an agent is unusable (and leaks the
  harness's layout).

  ## Limits and lifetime

  At most `caps["shell"]["background"]` jobs (default 1) may run
  concurrently per agent; `0` disables background jobs. Jobs are keyed
  by `{space_id, agent_name}` and die when their agent dies (the manager
  monitors the agent pid) or when `stop_all/1` runs at agent terminate.
  Finished jobs are retained (bounded) so `shell-wait` and `shell-list`
  can still report them.

  ## Events

  When an agent topic is known, the manager broadcasts
  `{:shell_jobs, %{jobs: [...]}}` on `"agent:<space_id>:<name>"` when a
  job starts, exits, or is killed, so the UI can render the running set.

  ## Blocking

  This GenServer never blocks for an unknown amount of time. Every
  callback does bounded, local work: `:exec.run`/`:exec.kill` are
  synchronous OS calls, and the only file I/O is `File.write` of a
  streamed chunk and `File.read` of a job's log (proportional to that
  log's size; logs are not capped on disk by design). It never waits on
  an agent, an LLM, or another process, so a `GenServer.call/3` to it is
  ordinary synchronous communication, not a blocking hand-off.
  """

  use GenServer

  alias Nest.PubSub
  alias Nest.Sandbox
  alias Nest.Tools.Exec
  alias Nest.Tools.ShellCmd

  @name __MODULE__
  @default_max_jobs 1
  @max_finished_per_agent 50
  # How long after a kill to force a terminal state if the exec port's
  # DOWN never arrives (SIGKILL + monitor should make it prompt).
  @kill_finalize_ms 5_000
  # Where the *space* scratch dir is mounted inside the sandbox, and the
  # subdirectory the job logs live in beneath the agent's own dir.
  @sandbox_tmp "/tmp"
  @log_subdir "shell-jobs"

  @type job_id :: String.t()
  @type agent_key :: {term(), term()}

  @type info :: %{
          id: job_id(),
          command: String.t(),
          status: :running | :exited,
          exit_code: integer() | nil,
          killed: boolean(),
          # The path inside the sandbox
          # (`/tmp/<agent-name>/shell-jobs/<id>.log`), not the host path
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
    * `:bwrap` — the full bwrap command line to run
    * `:script_path` — the staged script to remove once the job ends
    * `:tmp_path` — the host dir the log lives under (the agent's own
      scratch dir; the sandbox sees it at
      `#{@sandbox_tmp}/<agent-name>`)
    * `:max_jobs` — the per-agent ceiling (default #{@default_max_jobs})

  Returns `{:ok, job_id, log_path}`, where `log_path` is the path inside
  the sandbox, or `{:error, reason}`.
  """
  @spec start_job(map()) :: {:ok, job_id(), String.t()} | {:error, String.t()}
  def start_job(attrs) do
    # `:erlexec` is started lazily outside prod (see `Nest.Tools.Exec`).
    # Start it in the caller so the one-off 350ms never blocks this
    # server's mailbox.
    Exec.ensure_started()
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

  @doc "Kill a running job. Its exit code is reported once the process dies."
  @spec kill(agent_key(), job_id()) :: :ok | {:error, :not_found}
  def kill(agent_key, job_id), do: GenServer.call(@name, {:kill, agent_key, job_id})

  @doc "Stop every job belonging to `agent_key` (used at agent terminate)."
  @spec stop_all(agent_key()) :: :ok
  def stop_all(agent_key), do: GenServer.call(@name, {:stop_all, agent_key}, 10_000)

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
      |> Enum.sort_by(& &1.started_at, DateTime)
      |> Enum.map(&to_info/1)

    {:reply, jobs, state}
  end

  def handle_call({:status, agent_key, job_id}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, job_status(job)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:output, agent_key, job_id}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, job} -> {:reply, {:ok, read_log(job.log_path)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:subscribe, agent_key, job_id, pid}, _from, state) do
    case fetch_job(state, agent_key, job_id) do
      {:ok, %{status: {:exited, code}}} ->
        send(pid, {:shell_job_exit, job_id, code})
        {:reply, :ok, state}

      {:ok, _running} ->
        waiters = Map.update(state.waiters, job_id, [pid], &[pid | &1])
        {:reply, :ok, %{state | waiters: waiters}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unsubscribe, _agent_key, job_id, pid}, _from, state) do
    {:reply, :ok, remove_waiter(state, job_id, pid)}
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

  def handle_call({:stop_all, agent_key}, _from, state) do
    {:reply, :ok, drop_agent(agent_key, state)}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, state),
    do: {:noreply, write_output(os_pid, data, state)}

  def handle_info({:stderr, os_pid, data}, state),
    do: {:noreply, write_output(os_pid, data, state)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      job = job_by_erl_pid(state, pid) -> {:noreply, finish_job(job, reason, state)}
      agent_key = agent_key_by_monitor(state, pid) -> {:noreply, drop_agent(agent_key, state)}
      true -> {:noreply, state}
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
        case launch(attrs, agent_key, state) do
          {:ok, job, log_path} -> {:ok, job.id, log_path, put_job(state, job)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp launch(attrs, agent_key, state) do
    job_id = "job-#{state.next_id}"
    tmp_path = Map.fetch!(attrs, :tmp_path)
    log_dir = Path.join(tmp_path, @log_subdir)
    log_path = Path.join(log_dir, "#{job_id}.log")

    sandbox_log_path =
      Path.join([Sandbox.sandbox_tmp_path(tmp_path), @log_subdir, "#{job_id}.log"])

    with :ok <- File.mkdir_p(log_dir),
         :ok <- File.write(log_path, ""),
         {:ok, erl_pid, os_pid} <- run_process(Map.fetch!(attrs, :bwrap)) do
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

  defp run_process(bwrap) do
    :exec.run(
      to_charlist(bwrap),
      [:stdout, :stderr, :monitor, {:stdin, :null}, {:kill_timeout, 5000}]
    )
  end

  defp start_error(reason) when is_atom(reason), do: "Failed to start process: #{reason}"
  defp start_error({:error, reason}), do: start_error(reason)
  defp start_error(reason), do: "Failed to start process: #{inspect(reason)}"

  # ---- Output / completion ----

  defp write_output(os_pid, data, state) do
    case job_by_os_pid(state, os_pid) do
      nil ->
        state

      job ->
        File.write(job.log_path, data, [:append])
        state
    end
  end

  defp finish_job(job, reason, state) do
    code = exit_code(reason)

    state =
      state
      |> notify_waiters(job.id, code)
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
  # with it. On DOWN we drop every job under the key.
  defp track_agent(state, agent_key, attrs) do
    case Map.get(state.agents, agent_key) do
      nil ->
        case Map.get(attrs, :agent_pid) do
          pid when is_pid(pid) ->
            ref = Process.monitor(pid)
            %{state | agents: Map.put(state.agents, agent_key, %{pid: pid, ref: ref})}

          _ ->
            state
        end

      _existing ->
        state
    end
  end

  defp drop_agent(agent_key, state) do
    jobs = state.jobs |> Map.values() |> Enum.filter(&(&1.agent_key == agent_key))

    Enum.each(jobs, fn job ->
      if job.status == :running, do: stop_os_process(job)
      remove_script(job)
    end)

    case Map.get(state.agents, agent_key) do
      %{ref: ref} -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    %{
      state
      | jobs: Map.drop(state.jobs, Enum.map(jobs, & &1.id)),
        agents: Map.delete(state.agents, agent_key),
        waiters: Map.drop(state.waiters, Enum.map(jobs, & &1.id))
    }
  end

  # SIGKILL the running external process. Plain `:exec.stop/1` sends
  # SIGTERM first and only escalates to SIGKILL after ~5s; bwrap (PID 1 in
  # its namespace) can ignore SIGTERM, which made kills flaky-slow. We want
  # an immediate teardown.
  defp stop_os_process(%{os_pid: os_pid}) do
    :exec.kill(os_pid, :sigkill)
  catch
    _kind, _ -> :ok
  end

  # ---- Waiters ----

  defp notify_waiters(state, job_id, code) do
    pids = Map.get(state.waiters, job_id, [])

    Enum.each(pids, &send(&1, {:shell_job_exit, job_id, code}))
    update_in(state.waiters, &Map.delete(&1, job_id))
  end

  # Drop a single waiter without notifying it. Removes the job's key
  # entirely once its list empties.
  defp remove_waiter(state, job_id, pid) do
    case Map.get(state.waiters, job_id) do
      nil ->
        state

      pids ->
        case List.delete(pids, pid) do
          [] -> %{state | waiters: Map.delete(state.waiters, job_id)}
          remaining -> %{state | waiters: Map.put(state.waiters, job_id, remaining)}
        end
    end
  end

  # ---- Retention / cleanup ----

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
        File.rm(job.log_path)
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

  defp job_status(%{status: :running}), do: :running
  defp job_status(%{status: {:exited, code}}), do: {:exited, code}

  defp to_info(job) do
    %{
      id: job.id,
      command: job.command,
      status: if(job.status == :running, do: :running, else: :exited),
      exit_code: job.exit_code,
      killed: job.killed,
      # The path the sandbox sees, not the host path the manager writes:
      # it is what `shell-list` shows the agent and what the UI receives.
      # `Map.get` (not `job.sandbox_log_path`) so jobs already in a live
      # manager's state from before this field existed still render.
      log_path: Map.get(job, :sandbox_log_path, job.log_path),
      started_at: job.started_at
    }
  end

  defp read_log(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # ---- Broadcast ----

  defp broadcast(state, {space_id, name} = agent_key)
       when is_integer(space_id) and is_binary(name) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == agent_key))
      |> Enum.map(&to_info/1)

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
