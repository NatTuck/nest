defmodule Nest.Agents.Agent.Watch do
  @moduledoc """
  Interest registrations for the non-blocking waits (issues #54 + #62).

  `agents-wait` and `shell-wait` never block: the tool worker registers a
  watch, reports that it did, and the machine **ends the caller's turn** so the
  agent goes idle (issue #54) and a human can message it. A supervised task
  delivers a bare `:runtime` entry when the event fires, which wakes the idle
  agent.

  Reporting the registration is what makes the turn-ending exact: the tool
  result of a call that registered a watch carries `state: "waiting"` (the
  entry kind `BatchSizer` cooks it from), and
  `Machine.Transitions.tool_results/2` rests the turn for a batch whose results
  carry it. A wait with nothing to watch — every target already idle, no other
  agents in the space — registers nothing, returns an ordinary result, and the
  turn simply continues, which is why both functions below return `{:waiting,
  …}` and `{:ok, …}` as distinct shapes.

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
    if watching_any?(state.live.watches, name) do
      put_watches(state, Map.new(state.live.watches, &satisfy_entry(&1, name)))
    else
      state
    end
  end

  def satisfy(state, _name), do: state

  defp watching_any?(watches, name),
    do: Enum.any?(watches, fn {_ref, watch} -> watching?(watch.spec, name) end)

  defp satisfy_entry({ref, watch}, name) do
    if watching?(watch.spec, name), do: {ref, %{watch | satisfied: true}}, else: {ref, watch}
  end

  defp put_watches(state, watches),
    do: %{state | live: %{state.live | watches: watches}}

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

        {:reply, {:ok, disposition}, state} =
          Inbox.deliver_internal(state, nil, content, :runtime)

        {state, disposition}
    end
  end

  @doc """
  Register interest for an `agents-wait` call (issue #54). Resolves the
  targets; a wait with nothing to watch reports inline and registers nothing.

  Returns `{:waiting, confirmation}` when a watch is now outstanding (the
  caller's turn ends), `{:ok, confirmation}` when every target was already idle
  or the space holds no other agent (the caller's turn continues), or
  `{:error, content}` when the call was refused and registered nothing.
  """
  @spec register_call(map(), Nest.Messages.ToolCall.t()) ::
          {:waiting, String.t()} | {:ok, String.t()} | {:error, String.t()}
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
        {:waiting, WaitForIdle.watch_confirmation(partition)}

      {:error, reason} ->
        Agent.unregister_watch(ctx.agent_pid, ref)
        {:error, "Could not start the watch: #{inspect(reason)}"}
    end
  end

  @doc """
  Register interest for a `shell-wait` call (issue #54). Returns
  `{:waiting, confirmation}` when the watch is now outstanding (the caller's
  turn ends) or `{:error, content}` when it could not be registered. The
  watcher delivers the job's result as a notice.
  """
  @spec register_shell_call(map(), String.t(), pos_integer()) ::
          {:waiting, String.t()} | {:error, String.t()}
  def register_shell_call(ctx, id, timeout) do
    key = Nest.Tools.agent_key(ctx)
    ref = make_ref()
    spec = {:shell_job, key, id, timeout}
    :ok = Agent.register_watch(ctx.agent_pid, ref, spec)

    case start(ctx.agent_pid, ref, spec) do
      {:ok, pid} ->
        Agent.watch_attached(ctx.agent_pid, ref, pid)
        {:waiting, "Watching background job #{id}; its result will arrive as a message."}

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
    # The reference read for what `any` waits for. It is taken before the
    # subscription on purpose (`WaitForIdle.await/6` re-reads the authority
    # after subscribing, so nothing can slip between the two).
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
        {:event, shell_result(key, id, code)}

      # The job's agent stopped, so the job went with it. In production this is
      # the watcher's own caller (`register_shell_call/3` keys the job to the
      # calling agent), and the message is sent from that agent's `terminate/2`
      # — so it can arrive just before this watcher's monitor DOWN. Worded as
      # what it is rather than as an exit: there is no exit code, and the log
      # goes with the agent's tmp directory.
      {:shell_job_gone, ^id} ->
        ShellJobs.unsubscribe(key, id, self())
        {:event, ShellJobs.gone_text(id)}
    after
      timeout ->
        ShellJobs.unsubscribe(key, id, self())

        {:event,
         "Timed out after #{timeout}ms waiting for background job #{id}; it is still running."}
    end
  end

  # `output/2` returns `{:error, :not_found}` once the job is gone (it can be
  # dropped as the agent stops), so this must not hard-match: a crash here would
  # leave the watch uncleared and deliver no wake.
  defp shell_result(key, id, code) do
    case ShellJobs.output(key, id) do
      {:ok, output} -> ShellJobs.result_text(id, code, output)
      {:error, _} -> "Background job #{id} exited with code #{code} (output no longer available)."
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
