defmodule Nest.Agents.Agent.Watch do
  @moduledoc """
  Interest registrations for the non-blocking waits (issues #54 + #62).

  `agents-wait-for-idle` and `shell-wait` return immediately by default: the
  tool worker registers a watch, the agent ends its turn and goes **idle** so a
  human can message it (issue #54), and a supervised task delivers a bare
  `:notice` when the event fires.

  ## The registration

  A watch is `%{pid, spec, satisfied}` keyed by a `make_ref/0` the tool worker
  minted. The worker registers it (`Agent.register_watch/3`) *before* starting
  the task, so a task that fires immediately still finds its watch; it attaches
  the task's pid once it is up, and unregisters if the task could not start.

  ## The satisfied-watch suppression (issue #62 requirement 1)

  Idle implies delivered: an agent's completion is sent before it is observable
  idle, so by the time a watch on it fires, its body is already in the caller's
  inbox and has already woken (or will wake) the caller. `satisfy/2` marks the
  watch when that delivery arrives, and `fired/3` then **skips** the notice — so
  the caller wakes exactly once, from the body, never twice.

  ## Lifetime

  The task monitors the caller and exits quietly when it dies. `stop_all/1` is
  the Stop path's `{:stop_watchers}` action: it kills every outstanding watcher
  so a stopped turn cannot be woken by a notice it no longer wants (the gap
  `notes/review-pr25.md` recorded).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.WaitForIdle
  alias Nest.Sandbox.ShellJobs

  @doc "Store a watch the tool worker just registered."
  @spec register(Agent.t(), reference(), term()) :: Agent.t()
  def register(state, ref, spec) do
    watch = %{pid: nil, spec: spec, satisfied: false}
    put_watch(state, ref, watch)
  end

  @doc "Record the watcher task's pid once it is up."
  @spec attach(Agent.t(), reference(), pid()) :: Agent.t()
  def attach(state, ref, pid) do
    case Map.fetch(state.live.watches, ref) do
      {:ok, watch} -> put_watch(state, ref, %{watch | pid: pid})
      :error -> state
    end
  end

  @doc "Drop a watch (its task finished, or its task could not be started)."
  @spec unregister(Agent.t(), reference()) :: Agent.t()
  def unregister(state, ref) do
    %{state | live: %{state.live | watches: Map.delete(state.live.watches, ref)}}
  end

  @doc """
  Mark every watch covering `name` satisfied: a delivery from `name` arrived,
  so the caller is already being woken by the body and the bare notice would be
  a second wake (issue #62 requirement 1).
  """
  @spec satisfy(Agent.t(), String.t() | nil) :: Agent.t()
  def satisfy(state, name) when is_binary(name) do
    if Enum.any?(state.live.watches, fn {_ref, watch} -> watching?(watch.spec, name) end) do
      watches =
        Map.new(state.live.watches, fn {ref, watch} ->
          if watching?(watch.spec, name),
            do: {ref, %{watch | satisfied: true}},
            else: {ref, watch}
        end)

      %{state | live: %{state.live | watches: watches}}
    else
      state
    end
  end

  def satisfy(state, _name), do: state

  @doc "Kill every outstanding watcher and clear the map (the Stop path)."
  @spec stop_all(Agent.t()) :: Agent.t()
  def stop_all(state) do
    Enum.each(state.live.watches, fn {_ref, watch} ->
      if is_pid(watch.pid), do: Process.exit(watch.pid, :kill)
    end)

    %{state | live: %{state.live | watches: %{}}}
  end

  @doc """
  The caller's decision on a watcher firing: deliver the notice unless the
  watch was already satisfied by the target's own delivery, then drop the
  watch. Returns the state and the disposition.
  """
  @spec fired(Agent.t(), reference(), String.t()) ::
          {Agent.t(), :delivered | :queued | :skipped}
  def fired(state, ref, content) do
    case Map.fetch(state.live.watches, ref) do
      :error ->
        {state, :skipped}

      {:ok, %{satisfied: true}} ->
        {unregister(state, ref), :skipped}

      {:ok, _watch} ->
        state = unregister(state, ref)
        {:reply, {:ok, disposition}, state} = Inbox.deliver_internal(state, nil, content, :notice)
        {state, disposition}
    end
  end

  @doc """
  Register interest for an `agents-wait-for-idle` call (issue #54). Resolves
  the targets; already-idle-only waits report inline and register nothing.
  Returns `{:ok, confirmation}` or `{:error, content}`.
  """
  @spec register_call(map(), Nest.Messages.ToolCall.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def register_call(ctx, %Nest.Messages.ToolCall{} = tc) do
    case WaitForIdle.resolve(ctx, tc) do
      {:error, content} ->
        {:error, content}

      {:ok, [], _timeout, _all?, _initial} ->
        {:ok, "No other agents in this space to wait for."}

      {:ok, names, timeout, all?, initial} ->
        if initial.still_busy == [] do
          {:ok, WaitForIdle.watch_confirmation(initial)}
        else
          start_agent_watch(ctx, names, timeout, all?, initial)
        end
    end
  end

  defp start_agent_watch(ctx, names, timeout, all?, partition) do
    ref = make_ref()
    spec = {:agent_idle, ctx.space_id, names, timeout, all?}
    :ok = Agent.register_watch(ctx.agent_pid, ref, spec)

    case start(ctx.agent_pid, ref, spec) do
      {:ok, pid} ->
        Agent.watch_attached(ctx.agent_pid, ref, pid)
        {:ok, WaitForIdle.watch_confirmation(partition)}

      {:error, reason} ->
        Agent.unregister_watch(ctx.agent_pid, ref)
        {:error, "Could not start the watch: #{inspect(reason)}"}
    end
  end

  @doc """
  Register interest for a `shell-wait` call (issue #54). Returns the
  confirmation text; the watcher delivers the job's result as a notice.
  """
  @spec register_shell_call(map(), String.t(), pos_integer()) :: {:ok, String.t()}
  def register_shell_call(ctx, id, timeout) do
    key = Nest.Tools.agent_key(ctx)
    ref = make_ref()
    spec = {:shell_job, key, id, timeout}
    :ok = Agent.register_watch(ctx.agent_pid, ref, spec)

    case start(ctx.agent_pid, ref, spec) do
      {:ok, pid} ->
        Agent.watch_attached(ctx.agent_pid, ref, pid)
        {:ok, "Watching background job #{id}; its result will arrive as a message."}

      {:error, reason} ->
        Agent.unregister_watch(ctx.agent_pid, ref)
        {:error, "Could not start the watch: #{inspect(reason)}"}
    end
  end

  @doc """
  Spawn the watcher task for `spec`, under the shared `Task.Supervisor` so it
  outlives the tool worker's turn.
  """
  @spec start(pid(), reference(), term()) :: {:ok, pid()} | {:error, term()}
  def start(agent_pid, ref, spec) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      # Prepend the agent to the inherited `$callers` chain rather than
      # replacing it: the chain is how the DB sandbox and Mimic resolve the
      # owning test process (and how tracing finds the agent).
      Process.put(:"$callers", [agent_pid | List.wrap(Process.get(:"$callers"))])
      run(agent_pid, ref, spec)
    end)
  end

  @doc "The watcher task body. Monitors the caller so it never outlives it."
  @spec run(pid(), reference(), term()) :: :ok
  def run(agent_pid, ref, spec) do
    monitor = Process.monitor(agent_pid)

    case await(spec, monitor) do
      :caller_down -> :ok
      {:event, content} -> deliver(agent_pid, ref, content)
    end
  end

  defp await({:agent_idle, space_id, names, timeout, all?}, monitor) do
    initial = WaitForIdle.partition(space_id, names)

    case WaitForIdle.await(space_id, names, timeout, all?, initial, monitor) do
      :caller_down -> :caller_down
      {:ok, partition} -> {:event, WaitForIdle.notice_text(partition)}
      {:timeout, partition} -> {:event, WaitForIdle.timeout_notice_text(partition, timeout)}
    end
  end

  defp await({:shell_job, key, id, timeout}, monitor) do
    case ShellJobs.subscribe(key, id, self()) do
      {:error, :not_found} ->
        {:event, "Background job #{id} no longer exists."}

      :ok ->
        await_shell_job(key, id, timeout, monitor)
    end
  end

  defp await_shell_job(key, id, timeout, monitor) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} ->
        ShellJobs.unsubscribe(key, id, self())
        :caller_down

      {:shell_job_exit, ^id, code} ->
        ShellJobs.unsubscribe(key, id, self())
        {:ok, output} = ShellJobs.output(key, id)
        {:event, ShellJobs.result_text(id, code, output)}
    after
      timeout ->
        ShellJobs.unsubscribe(key, id, self())

        {:event,
         "Timed out after #{timeout}ms waiting for background job #{id}; it is still running."}
    end
  end

  defp deliver(agent_pid, ref, content) do
    Agent.watch_fired(agent_pid, ref, content)
  catch
    :exit, _ -> :ok
  end

  defp watching?({:agent_idle, _space_id, names, _timeout, _all?}, name), do: name in names
  defp watching?(_spec, _name), do: false

  defp put_watch(state, ref, watch) do
    %{state | live: %{state.live | watches: Map.put(state.live.watches, ref, watch)}}
  end
end
