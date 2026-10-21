defmodule Nest.Agents.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing agent processes.

  Provides functions to start, stop, and list agents.

  ## Persistence

  `fetch_or_start_agent/2` is the single entry point for
  every caller that wants an agent running. It takes `space_id`
  as the first argument. Agent names are unique within a space.
  """

  use DynamicSupervisor

  require Logger

  alias Nest.Agents.{Agent, ChildRegistry, NameGenerator, Registry, SpaceGate, SpawnVocation}
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Turn.GiveUpDelivery
  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts
  alias Nest.Spaces
  alias Nest.Vocations

  @supervisor_name __MODULE__

  @doc """
  Returns the child specification for starting the supervisor.
  """
  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{
      id: @supervisor_name,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  @doc """
  Starts the supervisor linked to the current process.
  """
  @spec start_link() :: Supervisor.on_start()
  def start_link do
    DynamicSupervisor.start_link(__MODULE__, [], name: @supervisor_name)
  end

  @doc """
  Fetch or start the agent with the given `space_id` and attrs.

  The DB is the source of truth for "does this agent exist in this space?": a row
  starts a fresh process under the supervisor, and no row is `{:error, :not_found}`.

  The load-time sequence heal (`Agent.pre_load_heal/1`) runs here, in the
  caller's DB context, before the child is spawned — never in the child's
  `init/1` (see the hard rule there). It is idempotent: a caller that finds the
  tail already healed appends nothing, and both callers get `{:ok, name}`.

  Returns `{:ok, name}` on success.
  """
  @spec fetch_or_start_agent(integer(), map()) :: {:ok, String.t()} | {:error, term()}
  def fetch_or_start_agent(space_id, attrs) do
    # A start reads the row for the environment values, so it waits out an edit.
    :ok = SpaceGate.await(space_id)

    case Map.get(attrs, :name) do
      nil ->
        {:error, :not_found}

      existing_name ->
        case safe_fetch_for_start(space_id, existing_name) do
          {:ok, start_attrs} ->
            start_under_supervisor(Agent.pre_load_heal(start_attrs), existing_name)

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp safe_fetch_for_start(space_id, name) do
    case Persistence.build_attrs_for_start(space_id, name) do
      {:ok, attrs} ->
        {:ok, attrs}

      # `:not_found` and `:archived` are ordinary refusals of the caller's request,
      # not fetch failures: a missing row, and one deliberately out of service. The
      # caller surfaces them (the channel answers `agent not found`/`agent_archived`).
      {:error, reason} when reason in [:not_found, :archived] ->
        {:error, reason}

      {:error, reason} ->
        Logger.warning("Failed to fetch agent #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_under_supervisor(attrs, name) do
    with :ok <- workspace_gate(attrs),
         {:ok, prepared} <- prepare_for_start(attrs),
         {:ok, _pid} <- DynamicSupervisor.start_child(@supervisor_name, {Agent, prepared}) do
      {:ok, name}
    else
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  # The config-file gate on the one route that never reaches `Sandbox.build/4`.
  # `Nest.ConfigFile.error/1` explains why it is needed and why it is direct.
  defp workspace_gate(%{workspace_path: path}) when is_binary(path),
    do: Nest.ConfigFile.error(path)

  defp workspace_gate(_attrs), do: :ok

  # Compose the expensive part of the initial state here, in the caller, rather
  # than inside `init/1` — `init/1` runs with this supervisor blocked until it
  # returns, so the composition it does was paid *serially* by every agent
  # start. See `Nest.Agents.Agent.Init.prepare/1`.
  #
  # The rescue is a **boundary guard with no known reachable cause** (composition
  # touches no sandbox, creates no scratch directory, and renders a malformed
  # `.nest` as an error section). It stays because `fetch_or_start_agent/2` and
  # `get_agent/2` are channel-called and log nothing, so a raise would escape.
  defp prepare_for_start(attrs) do
    {:ok, Init.prepare(attrs)}
  rescue
    exception ->
      Logger.error("Could not prepare the agent's initial state: #{Exception.message(exception)}")
      {:error, {:prepare_failed, exception}}
  end

  @doc """
  Run the start call for a row `Agent.pre_spawn/1` just inserted, removing
  that row when no process started.

  Every pre-spawn site has the same shape: insert the row (and its system
  message), then start the process. A start that does not happen leaves an
  orphan that also blocks every retry with the same name
  (`unique_constraint([:space_id, :name])`). `start` is the call that starts the
  agent — `fetch_or_start_agent/2` for a caller-created agent,
  `start_under_supervisor/2` for a spawn — and its `{:ok, name}` passes through.

  Anything else means no process exists for `attrs`:

    * an `{:error, reason}` return (a failed `init/1`, a `:not_found` race);
    * an exception raised on the way, e.g. inside `Agent.pre_load_heal/1`,
      which is why this is a `rescue` and not just a `case`. The exception
      is re-raised unchanged after the cleanup — it is the caller's failure
      to report, not ours to swallow.

  The delete is by `id`, never by name: this can only ever remove the row the
  caller inserted, and a concurrent caller's row would be a different `id`.
  Deleting also cascades to the messages the same `pre_spawn/1` wrote
  (`messages.agent_id` is `on_delete: :delete_all`).

  A start that reports `{:ok, name}` (including `:already_started`, which
  means some other caller's process owns the name) removes nothing.
  """
  @spec start_pre_spawned(map(), integer(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def start_pre_spawned(attrs, agent_id, start) when is_integer(agent_id) do
    start.()
  rescue
    exception ->
      rollback_pre_spawned(attrs, agent_id, exception)
      reraise exception, __STACKTRACE__
  else
    {:ok, name} ->
      {:ok, name}

    {:error, reason} ->
      rollback_pre_spawned(attrs, agent_id, reason)
      {:error, reason}
  end

  # The clone's attrs: its forked message prefix, tree position, and inherited
  # config. Kept as a function so `start_agent_with_parent/3` stays under the
  # ABC cap.
  defp clone_attrs(parent_state, instruction, child_name, parent_id, model_override, mode) do
    Agent.build_child_attrs(
      parent_state,
      instruction,
      child_name,
      parent_id,
      model_override,
      mode
    )
  end

  # `start_pre_spawned/3` bound to this module's own start call. Kept as a
  # function so the `with` in the spawn paths stays under the ABC cap.
  #
  # The row id and the row's mode are attached here rather than returned from
  # `pre_spawn/1`: a spawned child starts straight from these attrs (a
  # caller-created agent's come from `Persistence.build_attrs_for_start/2`), so
  # its session must know which row it owns before its first append, and its mode
  # must be the *row's* — `PreSpawn.put_mode/1` derived it into its own copy, so
  # a spawn that named none fell back to `Nest.Modes.default()`: a `plan`
  # parent's child running `act`, writing a workspace its parent may not touch.
  defp start_pre_spawned_child(attrs, agent_id, name) do
    attrs = Map.put(attrs, :agent_row_id, agent_id)
    # Inside the closure, so a missing row is rolled back (see `start_pre_spawned/3`).
    start_pre_spawned(attrs, agent_id, fn ->
      start_under_supervisor(Map.put(attrs, :mode, persisted_mode(attrs, agent_id)), name)
    end)
  end

  # By `id`, not by name: a name outlives its row, so a teardown or a concurrent
  # create could hand the child its successor's mode — the widening direction.
  defp persisted_mode(attrs, agent_id) do
    {:ok, %PersistedAgent{id: ^agent_id, mode: mode}} =
      Persistence.fetch_agent(attrs.space_id, attrs.name)

    mode
  end

  defp rollback_pre_spawned(attrs, agent_id, reason) do
    Logger.warning(
      "Agent #{attrs.space_id}/#{attrs.name} (id #{agent_id}) failed to start " <>
        "(#{inspect(reason)}); removing the row it pre-spawned"
    )

    Persistence.delete_agent_by_id(agent_id)
  end

  @doc """
  Test-only: start a single agent under the supervisor.

  Heals in the caller's DB context first (matching `fetch_or_start_agent/2`) and
  runs the config-file gate, because it is a start route like any other.
  """
  @spec start_under_test(map()) :: {:ok, pid()} | {:error, term()}
  def start_under_test(attrs) do
    _name = Map.fetch!(attrs, :name)

    with :ok <- workspace_gate(attrs),
         {:ok, prepared} <- prepare_for_start(Agent.pre_load_heal(attrs)),
         {:ok, pid} <- DynamicSupervisor.start_child(@supervisor_name, {Agent, prepared}) do
      {:ok, pid}
    else
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawn a child agent as a descendant of `parent_state`. The
  child inherits `parent_state.space_id` so cascade-termination
  scoped to that space will find it.
  """
  @spec start_agent_with_parent(Nest.Agents.Agent.t(), String.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_agent_with_parent(parent_state, instruction, model_override \\ nil, opts \\ [])
      when is_map(parent_state) and is_binary(instruction) do
    parent_name = parent_state.name
    space_id = parent_state.space_id

    # A spawn reads the space's environment (`Persistence.build_agent_attrs/1`
    # resolves the workspace from the row) and starts a process from it, and this
    # path does *not* go through `fetch_or_start_agent/2` — so the latch has to be
    # taken here, before the read, not only at the tool gate the spawn arrived
    # through. A spawn that passed the tool gate a moment before the latch went up
    # would otherwise start a child on the values the edit is replacing, and that
    # child is new: nothing casts it the change, and no mark exists for it yet.
    :ok = SpaceGate.await(space_id)

    with {:ok, %PersistedAgent{id: parent_id}} <- Persistence.fetch_agent(space_id, parent_name),
         child_name <- generate_unique_name_for_space(space_id),
         attrs =
           clone_attrs(
             parent_state,
             instruction,
             child_name,
             parent_id,
             model_override,
             Keyword.get(opts, :mode)
           ),
         {:ok, agent_id} <- Agent.pre_spawn(attrs),
         {:ok, _pid} <- start_pre_spawned_child(attrs, agent_id, child_name),
         :ok <- ChildRegistry.register(space_id, parent_name, child_name) do
      {:ok, child_name}
    end
  end

  @doc """
  Spawn a fresh-context sub-agent in the coordinator's space.

  Unlike `start_agent_with_parent/2` (which forks the parent's
  message history), this creates a specialist with a fresh
  system-prompt-only context. The child is a tracked child at
  `depth = parent.depth + 1` (so depth-limited recursion
  applies uniformly to clones and fresh spawns).

  The spawn is authorized against the space's blueprint
  `spawnable_vocations` whitelist: an unrestricted space
  (no blueprint, or empty list) allows any vocation;
  otherwise the effective vocation slug must be whitelisted.

  `vocation` may be `nil` (the `agents-spawn` default when
  the model omits it), and a blank string counts as omitted.
  Resolution rules:
    * an explicit vocation slug is used as-is (refused if not
      whitelisted),
    * otherwise the space's blueprint `default_spawnable_vocation`
      is used, and is itself held to the whitelist,
    * otherwise — the blueprint names no default — the spawn is
      refused as `{:vocation_required, allowed}`, naming the
      argument the caller has to supply. There is deliberately
      **no** fallback to the caller's own vocation: a
      `programmer` coordinator spawning an unnamed reviewer used
      to get another `programmer`, which is the glitch this
      replaces.

  `name` must be unique within the space (enforced by the
  `(space_id, name)` composite unique index; a collision
  surfaces as `{:error, :duplicate_name}`).

  Returns `{:ok, name}` on success.
  """
  @spec spawn_agent_in_space(
          Nest.Agents.Agent.t(),
          String.t(),
          String.t() | nil,
          map() | nil,
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def spawn_agent_in_space(
        parent_state,
        name,
        vocation \\ nil,
        model_override \\ nil,
        opts \\ []
      )
      when is_map(parent_state) and is_binary(name) do
    # See `start_agent_with_parent/4`: the spawn's own start path bypasses
    # `fetch_or_start_agent/2`, so the latch is taken here, before the row is
    # read.
    :ok = SpaceGate.await(parent_state.space_id)

    with {:ok, resolved} <- resolve_spawn_vocation(parent_state, vocation),
         :ok <- ensure_spawn_workspace(parent_state, resolved),
         {:ok, %PersistedAgent{id: parent_id}} <-
           Persistence.fetch_agent(parent_state.space_id, parent_state.name),
         :ok <-
           start_fresh_child(
             parent_state,
             name,
             resolved,
             parent_id,
             model_override,
             Keyword.get(opts, :mode)
           ) do
      {:ok, name}
    end
  end

  # Which vocation a spawn resolves to — the blueprint whitelist, the default, and
  # the refusal labels — lives in `Nest.Agents.SpawnVocation`, which is its own
  # module so this one stays under the file-length cap. Public here because the
  # docs that describe the resolution rules point at it.
  @doc false
  defdelegate resolve_spawn_vocation(parent_state, requested),
    to: SpawnVocation,
    as: :resolve

  # Build a fresh-context child's attrs (with `agents-spawn`
  # excluded when the child is at max depth), pre-spawn, start
  # it, and register it in `ChildRegistry`. Kept separate so
  # `spawn_agent_in_space/3` stays under the credo ABC cap.
  defp start_fresh_child(parent_state, name, vocation_id, parent_id, model_override, mode) do
    exclude_spawn = max_depth_reached?(parent_state.depth + 1)

    attrs =
      Agent.SubAgent.build_fresh_child_attrs(
        parent_state,
        name,
        parent_id,
        vocation_id,
        exclude_spawn,
        model_override,
        mode
      )
      |> Persistence.build_agent_attrs()

    with {:ok, agent_id} <- Agent.pre_spawn(attrs),
         {:ok, _pid} <- start_pre_spawned_child(attrs, agent_id, name) do
      ChildRegistry.register(parent_state.space_id, parent_state.name, name)
    end
  end

  # A child spawned at max depth cannot itself spawn children.
  # Only used for fresh (non-clone) spawns — clones must keep
  # the parent's exact tool list, so they never set this.
  defp max_depth_reached?(child_depth) do
    child_depth >= Config.configured_max_depth()
  end

  # A sub-agent whose vocation expects a workspace can't be spawned if
  # the parent has no workspace to inherit (e.g. a Chat parent spawning
  # a Programmer child). Reject immediately rather than starting a child
  # whose file/shell tools would fail at runtime.
  defp ensure_spawn_workspace(parent_state, vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil ->
        :ok

      _vocation ->
        # Every vocation requires a workspace now
        # (`Vocations.requires_workspace?/1` is a constant), so the child's
        # inheritance is all that is left to check.
        if is_nil(Mounts.workspace(parent_state.mounts)) do
          {:error, :workspace_required}
        else
          Nest.Sandbox.workspace_error(Mounts.workspace(parent_state.mounts))
        end
    end
  end

  @doc """
  Stops an agent by its `{space_id, name}`. Stops only the
  named agent's process — it does NOT cascade to descendants.
  Stopping an agent's outstanding queries is handled by the
  agent's own Stop path (which targets `pending_children`);
  archiving a whole subtree is handled by `archive_agent/2`.
  """
  @spec stop_agent(integer(), String.t()) :: :ok | {:error, :not_found}
  def stop_agent(space_id, name) do
    stop_one(space_id, name, :stopped)
  end

  @doc """
  Synchronously stop an agent and start it again, re-reading the DB.

  Unlike `stop_agent/2` (which fires `Process.exit/2` and returns
  before the process is gone), this terminates the child through the
  `DynamicSupervisor` so the Registry name is free before the restart,
  then reloads via `fetch_or_start_agent/2`. Used by
  `Nest.Agents.reload_agent/2` after an offline message repair.
  """
  @spec restart_agent(integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def restart_agent(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@supervisor_name, pid)
      {:error, :not_found} -> :ok
    end

    fetch_or_start_agent(space_id, %{name: name})
  end

  @doc """
  Stops an agent by its `{space_id, name}` and marks its DB
  row archived, then recursively does the same for every
  ChildRegistry descendant. Used by the `agents-archive` tool
  and the `archive` spawn flag, so archiving a parent stops
  AND archives its whole subtree. `:ok` whether or not the
  process was running; the DB rows are still marked archived
  either way.
  """
  @spec archive_agent(integer(), String.t()) :: :ok | {:error, :not_found}
  def archive_agent(space_id, name) do
    for child_name <- ChildRegistry.children_of(space_id, name) do
      _ = archive_agent(space_id, child_name)
    end

    _ = stop_one(space_id, name, :archive)
    result = Persistence.archive_agent(space_id, name)

    if result == :ok do
      broadcast_agent_archived(space_id, name)
    end

    result
  end

  # Tell the lobby clients that can see `space_id` that `name` was archived so
  # the sidebar can move it into the per-space "Archived" group without a
  # reload. Broadcast for each agent in the subtree (the recursion above
  # archives descendants too), matching `SubAgent`'s `agent:created` style.
  # The frame rides the per-space topic (#41), so it reaches only clients whose
  # user can see this space.
  defp broadcast_agent_archived(space_id, name) do
    Broadcasts.agent_archived(space_id, %{
      "space_id" => space_id,
      "name" => name
    })
  end

  @doc """
  Restore an archived agent in `space_id` to the active list.

  Restores the agent **and its whole archived subtree**: archiving a
  parent stops *and* archives its descendants, so the rows are walked
  through the persisted `parent_id` links (see
  `Persistence.unarchive_agent/2`) and the flag is cleared for all of
  them. None are eagerly restarted — each is rehydrated on demand by
  `get_agent/2` when it is next addressed (mirroring
  `Nest.Spaces.unarchive_space/1`).

  Broadcasts `agent:unarchived` on the lobby topic once per restored
  agent so connected clients can move them out of the per-space
  "Archived" group.

  Restoring an agent that is already active is a no-op (`:ok`).
  Restoring a child whose parent is still archived is refused with
  `{:error, {:parent_archived, parent_name}}` — the sidebar nests by
  `parent_name`, so such a child would render inside the archived
  parent's collapsed group and look like nothing happened. Returns
  `{:error, :not_found}` if the agent row does not exist.
  """
  @spec unarchive_agent(integer(), String.t()) :: :ok | {:error, term()}
  def unarchive_agent(space_id, name) do
    case Persistence.unarchive_agent(space_id, name) do
      {:ok, restored} ->
        Enum.each(restored, &broadcast_agent_unarchived(space_id, &1))
        :ok

      {:error, _reason} = err ->
        err
    end
  end

  # Tell every connected lobby client that `name` was restored so the
  # sidebar can move it back into the active tree without a reload.
  defp broadcast_agent_unarchived(space_id, name) do
    NestWeb.Endpoint.broadcast("lobby", "agent:unarchived", %{
      "space_id" => space_id,
      "name" => name
    })
  end

  # `reason` names the site for the give-up's log line and its timeline event
  # (`:stopped` for a plain Stop, `:archive` for an archive) — `stop_one/3`
  # serves both, so a hardcoded atom would misreport one of them.
  defp stop_one(space_id, name, reason) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        # A stop ends the agent, so the replies it still owes are given up
        # *before* the process goes away (issue #31 decision 12). A reload
        # (`restart_agent/2`) deliberately skips this: the agent comes back with
        # a fresh machine, and the loss is logged instead.
        _ = GiveUpDelivery.give_up_before_stop(pid, reason)
        Process.exit(pid, :shutdown)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the pid of an agent by its `{space_id, name}`.

  Loads the agent from the database when it is not running (`on_demand_load/2`).
  A caller that must not resurrect a stopped agent wants
  `get_running_agent/2` instead.
  """
  @spec get_agent(integer(), String.t()) :: {:ok, pid()} | {:error, term()}
  def get_agent(space_id, name) do
    case get_running_agent(space_id, name) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> on_demand_load(space_id, name)
    end
  end

  @doc """
  Get the pid of an agent that is *already running*, without loading one.

  Never reads the database, never starts a process: a name that is not running
  (or whose pid is dead) is `{:error, :not_found}`. The reply give-up resolves
  its requesters through this — a peer that sent us a query was running by
  definition, and "tell the requester no answer is coming" must never bring a
  stopped peer back to life and start a turn on it.
  """
  @spec get_running_agent(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_running_agent(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp on_demand_load(space_id, name) do
    case fetch_or_start_agent(space_id, %{name: name}) do
      {:ok, ^name} -> Registry.lookup(space_id, name)
      {:ok, _other} -> {:error, :name_collision}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1000
    )
  end

  @doc """
  Generate a unique agent name for a given space.
  """
  def generate_unique_name_for_space(space_id) do
    NameGenerator.generate_unique(existing_names_for_space(space_id))
  end

  @doc """
  Every known agent name in `space_id` — live (Registry) plus
  persisted (DB) — as a `MapSet`. The single source for "is this
  name already taken in this space?" checks (`generate_unique_name`
  and the batch child-namer).
  """
  @spec existing_names_for_space(integer()) :: MapSet.t(String.t())
  def existing_names_for_space(space_id) do
    MapSet.new(Registry.list_for_space(space_id) ++ persistence_list_names_for_space(space_id))
    |> MapSet.union(none_space_scratch_names(space_id))
  end

  # Names a *live* agent in a different `"none"` space is using as its scratch
  # directory. Two `"none"` spaces share the host's one `/tmp`, so those names
  # are taken in this space too — a name the generator would otherwise hand out
  # and the creation boundary would then refuse (see
  # `Nest.Agents.Agent.PreSpawn.pre_spawn/1`).
  #
  # Empty for any other backend: each of those spaces has its own scratch root,
  # where the same name is a different directory and is free.
  defp none_space_scratch_names(space_id) do
    if Spaces.sandbox_backend(space_id) == "none" do
      none_ids = Spaces.none_space_ids()

      Registry.list_all()
      |> Enum.filter(fn {other_space_id, _name} ->
        other_space_id != space_id and MapSet.member?(none_ids, other_space_id)
      end)
      |> Enum.map(fn {_space_id, name} -> name end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp persistence_list_names_for_space(space_id) do
    Persistence.list_agent_names_for_space(space_id)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
