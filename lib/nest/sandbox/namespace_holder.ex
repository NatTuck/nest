defmodule Nest.Sandbox.NamespaceHolder do
  @moduledoc """
  The per-space persistent process namespace (#224).

  A bwrap space's commands share one user + pid namespace, held open for the
  life of the space by a *holder* process, so `ps` inside a command sees the
  space's other commands and background jobs (#224). Each command still gets
  its own mount namespace (the mode's plan-RO / act-RW binds) and its own
  network namespace; only user + pid are shared.

  ## The holder

  The holder is `unshare --user --map-current-user --pid --fork --kill-child
  /bin/bash -c 'while :; do sleep 1; done'`. It creates an identity-mapped user
  namespace (`1000 -> 1000`, so commands run as the invoking user, never root)
  and a pid namespace whose PID 1 is bash — which reaps orphaned grandchildren,
  so a long-lived namespace does not accumulate zombies. `--kill-child` means
  stopping the holder tears the whole namespace down.

  A command joins it with `bwrap --userns <fd> --pidns <fd> --uid 1000 --gid
  1000 …`, the FDs opened from `/proc/<holder>/ns/{user,pid}` (see
  `Nest.Sandbox.Backend.Bwrap`). The holder must be created by `unshare`, not
  bwrap: a bwrap-created identity holder refuses the pid-namespace join.

  ## Ownership and lifecycle

  This module is a single manager (like `Nest.Sandbox.ShellJobs`) that owns
  every space's holder through erlexec's `:monitor`. The holder is parented to
  the runtime — never to the user's session manager — and a teardown stops only
  the holder's own verified OS pid. On a holder's death the manager starts a
  fresh one (a new *generation*); the namespace's jobs died with it, and
  reconciling them is `Nest.Sandbox.ShellJobs`'s business.

  `ensure/1` is lazy: the first bwrap command in a space starts the holder, and
  a space whose holder cannot start (no user namespaces on the host) falls back
  to the fresh per-command namespace, so a command never hard-fails on the
  holder's absence.
  """

  use GenServer

  require Logger

  @name __MODULE__

  # How long to wait for `unshare --fork` to produce the holder child whose
  # namespaces a command joins. A startup bound, not a poll loop in a test.
  @child_wait_ms 2_000
  @child_poll_ms 20

  defstruct holders: %{}, generation: 0

  @type holder :: %{holder_pid: String.t(), generation: non_neg_integer()}

  @doc "The registered name this manager runs under."
  @spec name() :: atom()
  def name, do: @name

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{id: @name, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: @name)

  @doc """
  The live holder for `space_id`, starting one if the space has none.

  Returns `{:ok, holder}` with the holder's host pid (the process whose
  `/proc/<pid>/ns/*` a command joins) and its generation, or `:error` when no
  holder can run — no space id, or the host cannot create the namespace. A
  caller that gets `:error` builds the fresh per-command namespace instead.
  """
  @spec ensure(integer() | nil) :: {:ok, holder()} | :error
  def ensure(nil), do: :error
  def ensure(space_id), do: GenServer.call(@name, {:ensure, space_id}, 10_000)

  @doc """
  Stop `space_id`'s holder and forget it. Called when the space is archived or
  deleted (`Nest.Sandbox.Backend.remove_space/3`). Stopping the holder's own
  verified pid tears the namespace down via `--kill-child`.
  """
  @spec stop_space(integer()) :: :ok
  def stop_space(space_id), do: GenServer.call(@name, {:stop_space, space_id})

  @impl true
  def init(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def handle_call({:ensure, space_id}, _from, state) do
    case Map.get(state.holders, space_id) do
      nil ->
        ensure_started(state, space_id)

      holder ->
        if holder_alive?(holder) do
          {:reply, {:ok, public(holder)}, state}
        else
          # The holder died but its :DOWN has not been processed yet; do not
          # hand back a dead namespace. Drop it and bring a fresh one up.
          state = %{state | holders: Map.delete(state.holders, space_id)}
          ensure_started(state, space_id)
        end
    end
  end

  def handle_call({:stop_space, space_id}, _from, state) do
    case Map.pop(state.holders, space_id) do
      {nil, _holders} ->
        {:reply, :ok, state}

      {holder, holders} ->
        stop_holder(holder)
        {:reply, :ok, %{state | holders: holders}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, erl_pid, reason}, state) do
    case pop_by_erl_pid(state.holders, erl_pid) do
      {nil, _holders} ->
        {:noreply, state}

      {holder, holders} ->
        # The namespace died with its holder; every job in it died too. The
        # jobs' own erlexec monitors mark them dead individually; chunk (a)
        # adds deterministic reconciliation + owner signaling here, keyed by
        # `holder.generation` (e.g. ShellJobs.namespace_lost(space_id, gen)).
        Logger.warning(
          "namespace holder for space #{holder.space_id} died (#{inspect(reason)}); " <>
            "restarting (generation #{holder.generation} lost)"
        )

        state = %{state | holders: holders}

        case start_holder(holder.space_id, state.generation + 1) do
          {:ok, fresh} -> {:noreply, put_holder(state, holder.space_id, fresh)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- holder process ----

  defp start_holder(space_id, generation) do
    case :exec.run(String.to_charlist(holder_command()), [:monitor, {:stdin, :null}]) do
      {:ok, erl_pid, os_pid} ->
        case read_holder_child(os_pid) do
          nil ->
            :exec.kill(os_pid, 9)
            Logger.warning("namespace holder for space #{space_id}: no child appeared")
            :error

          child_pid ->
            {:ok,
             %{
               space_id: space_id,
               os_pid: os_pid,
               erl_pid: erl_pid,
               holder_pid: child_pid,
               generation: generation
             }}
        end

      {:error, reason} ->
        Logger.warning(
          "namespace holder for space #{space_id} failed to start: #{inspect(reason)}"
        )

        :error
    end
  end

  # The holder command. bash is PID 1 in the new pid namespace and reaps
  # orphans; the sleep loop keeps it alive. `--kill-child` ties the namespace's
  # life to the unshare parent, which erlexec owns.
  defp holder_command do
    "unshare --user --map-current-user --pid --fork --kill-child " <>
      "/bin/bash -c 'while :; do sleep 1; done'"
  end

  # `unshare --fork` forks the holder child into the new namespaces; the parent
  # (os_pid) stays in the host's. The child's HOST pid — the one whose
  # /proc/<pid>/ns/* a command joins — is the parent's first child. Bounded
  # startup wait for the fork to land.
  defp read_holder_child(os_pid) do
    deadline = System.monotonic_time(:millisecond) + @child_wait_ms
    poll_holder_child(os_pid, deadline)
  end

  defp poll_holder_child(os_pid, deadline) do
    case File.read("/proc/#{os_pid}/task/#{os_pid}/children") do
      {:ok, contents} ->
        case String.split(contents) do
          [pid | _] -> pid
          _ -> retry_holder_child(os_pid, deadline)
        end

      _ ->
        retry_holder_child(os_pid, deadline)
    end
  end

  defp retry_holder_child(os_pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@child_poll_ms)
      poll_holder_child(os_pid, deadline)
    else
      nil
    end
  end

  defp stop_holder(holder) do
    # Only the holder's own verified pid — never a pid derived from a PPid.
    # SIGKILL, not :exec.stop's SIGTERM: unshare ignores SIGTERM while it waits
    # on its child, and --kill-child takes the namespace down with the parent.
    :exec.kill(holder.os_pid, 9)
  end

  defp put_holder(state, space_id, holder) do
    %{state | holders: Map.put(state.holders, space_id, holder), generation: holder.generation}
  end

  defp ensure_started(state, space_id) do
    case start_holder(space_id, state.generation + 1) do
      {:ok, holder} -> {:reply, {:ok, public(holder)}, put_holder(state, space_id, holder)}
      :error -> {:reply, :error, state}
    end
  end

  # The holder child (the namespace's PID 1) is alive iff its /proc entry is.
  defp holder_alive?(holder), do: File.exists?("/proc/#{holder.holder_pid}")

  defp public(holder), do: %{holder_pid: holder.holder_pid, generation: holder.generation}

  defp pop_by_erl_pid(holders, erl_pid) do
    case Enum.find(holders, fn {_id, h} -> h.erl_pid == erl_pid end) do
      {space_id, holder} -> {holder, Map.delete(holders, space_id)}
      nil -> {nil, holders}
    end
  end
end
