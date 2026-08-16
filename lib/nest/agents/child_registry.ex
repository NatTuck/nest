defmodule Nest.Agents.ChildRegistry do
  @moduledoc """
  In-process registry of parent → children relationships for
  sub-agents spawned through the `agents-spawn` tool (with
  `clone_context`).

  ## Why it exists

  `agents-spawn` produces a tree of GenServers: each spawned
  child runs as its own Agent under `Nest.Agents.Supervisor`
  and may itself spawn grandchildren up to a configured
  `max-depth`. When a parent is stopped (user-initiated Stop
  on the parent's chat, deletion, or a runtime crash that
  takes the parent down), its live descendants need to be
  stopped too — the runtime cascades termination
  separately from the database, where `agents.parent_id`
  uses `ON DELETE SET NULL` so a deleted parent orphans
  children rather than cascading the row delete.

  ## Space-scoped keys

  Every registration is keyed by `{space_id, name}` so that
  a parent and child named `clever-raven` in space 1 don't
  collide with the same names in space 2. The
  `Agents.Registry` is also partitioned by `{space_id, name}`,
  so the monitor target lookup (`AgentsRegistry.lookup/2`)
  matches the supervisor's address strategy.

  Operations the Agent GenServer and `Supervisor` need:

    * Lookup by name — `parent_of/2` for routing messages,
      `children_of/2` for cascade walks.
    * Register on spawn — the supervisor's
      `start_agent_with_parent/2` calls `register/3` after
      the child process is alive.
    * Self-cleanup on child death — each registered child
      is `Process.monitor/1`-ed via
      `Nest.Agents.Registry.via_tuple/2`. The DOWN handler
      removes the child from both maps.

  ## Naming and address strategy

  The ChildRegistry is a registered singleton GenServer
  named `Nest.Agents.ChildRegistry` (via the standard
  `:name` mechanism). All public API is `GenServer.call/2`
  to that name — no pid lookups. Monitors use
  `Process.monitor/1` against the child's via-tuple (not a
  raw pid) so we never hold a pid in our state — the
  monitor ref + via-tuple is the only addressable surface.

  ## Map shape

  Two mirrors of the same relationship:

    * `parent_to_children` —
      `%{{space_id, parent_name} => MapSet<{space_id, child_name}>}`
      Used for cascade termination (iterate, terminate each).
    * `child_to_parent` —
      `%{{space_id, child_name} => {space_id, parent_name}}`.
      Reverse lookup used by the broadcast / message-routing
      path when a child needs to send a notification to its
      parent.

  Both are updated under the registry's GenServer lock so
  they cannot diverge mid-operation.
  """

  use GenServer

  alias Nest.Agents.Registry, as: AgentsRegistry

  @registry_name __MODULE__

  # Client API

  @doc """
  Returns the registered name this GenServer is started
  under. Use it with `GenServer.call(__MODULE__, ...)` (or
  `GenServer.call(Nest.Agents.ChildRegistry, ...)` from
  outside this module) — no pid lookup needed.
  """
  @spec name() :: atom()
  def name, do: @registry_name

  @doc """
  Returns the supervisor child spec. Use this in the
  application supervision tree (and in tests that want a
  long-lived registry under `start_supervised!/1`).
  """
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{
      id: @registry_name,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  @doc """
  Start the registry under `child_spec/0`'s name. Idempotent.
  """
  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: @registry_name)
  end

  @doc """
  Register `child_name` as a descendant of `parent_name` in
  `space_id`. Installs a `Process.monitor/1` on the child's
  via-tuple so this registry self-cleans when the child dies
  for any reason (Stop, crash, supervisor shutdown).

  No-op if the child is already registered under the same
  parent (idempotent — the supervisor's `child_completed`
  handling can race a re-register).

  No-op if either name is `nil` — root agents never have a
  parent and shouldn't show up here.
  """
  @spec register(integer(), String.t(), String.t()) :: :ok
  def register(space_id, parent_name, child_name) do
    GenServer.call(@registry_name, {:register, space_id, parent_name, child_name})
  end

  @doc """
  Explicitly unregister `child_name` in `space_id`. Used by
  tests that want to inspect state without waiting for a
  DOWN. Production paths rely on the monitor-driven
  self-cleanup instead.
  """
  @spec unregister(integer(), String.t()) :: :ok
  def unregister(space_id, child_name) do
    GenServer.call(@registry_name, {:unregister, space_id, child_name})
  end

  @doc """
  Names of all registered children of `parent_name` in
  `space_id`. Returns an empty list (not `:not_found`) when
  the parent has no children — cascade walks iterate, not
  match.
  """
  @spec children_of(integer(), String.t()) :: [String.t()]
  def children_of(space_id, parent_name) do
    GenServer.call(@registry_name, {:children_of, space_id, parent_name})
  end

  @doc """
  Reverse lookup: the parent name for `child_name` in
  `space_id`, or `nil` if the child isn't registered (root
  agents never have a parent here).
  """
  @spec parent_of(integer(), String.t()) :: String.t() | nil
  def parent_of(space_id, child_name) do
    GenServer.call(@registry_name, {:parent_of, space_id, child_name})
  end

  @doc """
  Test-only: returns the two mapping mirrors. Use in tests
  that want to assert the structure without poking the
  public API.
  """
  @spec state() :: %{parent_to_children: map(), child_to_parent: map()}
  def state do
    GenServer.call(@registry_name, :state)
  end

  # Server callbacks

  @impl true
  def init(_args) do
    Process.flag(:trap_exit, true)
    {:ok, %{parent_to_children: %{}, child_to_parent: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, space_id, parent_name, child_name}, _from, state) do
    child_key = {space_id, child_name}

    state =
      case Map.get(state.child_to_parent, child_key) do
        nil ->
          do_register(state, space_id, parent_name, child_name)

        {^space_id, ^parent_name} ->
          # Already registered under the same parent; idempotent.
          state

        _other_parent ->
          # Re-registration under a different parent shouldn't
          # happen in production (each child has exactly one
          # parent at spawn time). Treat defensively: drop
          # the old link and clean up the stale monitor before
          # installing the new one.
          state = unregister_child(space_id, child_name, state)
          do_register(state, space_id, parent_name, child_name)
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, space_id, child_name}, _from, state) do
    {:reply, :ok, unregister_child(space_id, child_name, state)}
  end

  def handle_call({:children_of, space_id, parent_name}, _from, state) do
    children =
      state.parent_to_children
      |> Map.get({space_id, parent_name}, MapSet.new())
      |> Enum.map(fn {_sid, name} -> name end)

    {:reply, children, state}
  end

  def handle_call({:parent_of, space_id, child_name}, _from, state) do
    case Map.get(state.child_to_parent, {space_id, child_name}) do
      nil -> {:reply, nil, state}
      {_sid, parent_name} -> {:reply, parent_name, state}
    end
  end

  def handle_call(:state, _from, state) do
    {:reply,
     %{
       parent_to_children: state.parent_to_children,
       child_to_parent: state.child_to_parent
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Find the child whose monitor matches the ref and
    # remove it. If the ref doesn't match any registered
    # child, the registry has already cleaned up (e.g.
    # explicit `unregister/2` between DOWN arrival and
    # processing); drop the ref silently.
    child_key =
      Enum.find_value(state.monitors, fn {key, %{ref: r}} ->
        if r == ref, do: key
      end)

    state =
      case child_key do
        nil -> state
        {space_id, child_name} -> unregister_child(space_id, child_name, state)
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Private helpers

  # Add the mapping plus a monitor on the child process.
  # `Process.monitor/1` doesn't accept `{:via, Registry, _}`
  # tuples directly, so we resolve the via-tuple to the
  # child's pid at register time. The AgentsRegistry is
  # keyed by `{space_id, name}` (unique keys), so
  # `Registry.lookup/2` gives us the pid the supervisor
  # attached when it started the child.
  #
  # If the lookup misses (child died between start and
  # register — vanishingly rare), install no monitor and
  # let the caller handle the lifecycle. The next register
  # attempt, if any, will pick up a fresh pid.
  defp do_register(state, space_id, parent_name, child_name)
       when is_integer(space_id) and is_binary(parent_name) and is_binary(child_name) do
    monitor_ref = monitor_ref_for(state, space_id, child_name)

    %{
      state
      | parent_to_children:
          child_to_set(state.parent_to_children, space_id, parent_name, child_name),
        child_to_parent:
          Map.put(state.child_to_parent, {space_id, child_name}, {space_id, parent_name}),
        monitors: maybe_put_monitor(state.monitors, {space_id, child_name}, monitor_ref)
    }
  end

  # Look up — or install — the monitor reference for the
  # given child. Returns `nil` only when the lookup fails
  # (the child's pid can't be resolved).
  defp monitor_ref_for(state, space_id, child_name) do
    key = {space_id, child_name}

    case state.monitors[key] do
      %{ref: existing} ->
        existing

      nil ->
        case AgentsRegistry.lookup(space_id, child_name) do
          {:ok, pid} -> Process.monitor(pid)
          {:error, :not_found} -> nil
        end
    end
  end

  # Add `child_name` to the MapSet at `parent_name`,
  # returning the updated parent_to_children map.
  defp child_to_set(parent_to_children, space_id, parent_name, child_name) do
    parent_key = {space_id, parent_name}

    parent_to_children
    |> Map.get(parent_key, MapSet.new())
    |> MapSet.put({space_id, child_name})
    |> then(fn set -> Map.put(parent_to_children, parent_key, set) end)
  end

  defp maybe_put_monitor(monitors, _child_key, nil), do: monitors

  defp maybe_put_monitor(monitors, child_key, ref),
    do: Map.put(monitors, child_key, %{ref: ref})

  # Remove `child_name` from both maps and the monitor table.
  defp unregister_child(space_id, child_name, state) do
    child_key = {space_id, child_name}

    case Map.get(state.child_to_parent, child_key) do
      nil ->
        # Not registered (or already cleaned up); ensure
        # the monitors map is consistent anyway in case a
        # stale ref is still parked here.
        %{state | monitors: Map.delete(state.monitors, child_key)}

      {_sid, parent_name} ->
        monitors = Map.delete(state.monitors, child_key)
        parent_key = {space_id, parent_name}

        parent_to_children =
          state.parent_to_children
          |> Map.get(parent_key, MapSet.new())
          |> MapSet.delete(child_key)
          |> then(fn
            set when map_size(set) == 0 -> Map.delete(state.parent_to_children, parent_key)
            set -> Map.put(state.parent_to_children, parent_key, set)
          end)

        %{
          state
          | parent_to_children: parent_to_children,
            child_to_parent: Map.delete(state.child_to_parent, child_key),
            monitors: monitors
        }
    end
  end
end
