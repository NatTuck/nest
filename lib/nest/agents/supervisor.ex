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

  alias Nest.Agents.{Agent, ChildRegistry, NameGenerator, Registry}
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Turn.GiveUpDelivery
  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Spaces
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

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

  The DB is the source of truth for "does this agent exist in
  this space?":

    * If the row exists in `agents`, start a fresh process
      under the supervisor seeded with the active messages.
    * If no row exists, return `{:error, :not_found}`.

  The load-time sequence heal (`Agent.pre_load_heal/1`) runs here,
  in the caller's DB context, before the child is spawned — never in
  the child's `init/1` (see the hard rule there). It is idempotent: a
  caller that finds the tail already healed appends nothing, and both
  callers get `{:ok, name}`.

  Returns `{:ok, name}` on success.
  """
  @spec fetch_or_start_agent(integer(), map()) :: {:ok, String.t()} | {:error, term()}
  def fetch_or_start_agent(space_id, attrs) do
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

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Failed to fetch agent #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_under_supervisor(attrs, name) do
    case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Test-only: start a single agent under the supervisor.

  Applies `Agent.pre_load_heal/1` in the caller's DB context (matching
  `fetch_or_start_agent/2`) so an interrupted sequence is healed before
  the child spawns. The heal is idempotent, so an already-healed tail is
  left alone.
  """
  @spec start_under_test(map()) :: {:ok, pid()} | {:error, term()}
  def start_under_test(attrs) do
    _name = Map.fetch!(attrs, :name)

    case DynamicSupervisor.start_child(@supervisor_name, {Agent, Agent.pre_load_heal(attrs)}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Spawn a child agent as a descendant of `parent_state`. The
  child inherits `parent_state.space_id` so cascade-termination
  scoped to that space will find it.
  """
  @spec start_agent_with_parent(Nest.Agents.Agent.t(), String.t(), map() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def start_agent_with_parent(parent_state, instruction, model_override \\ nil)
      when is_map(parent_state) and is_binary(instruction) do
    parent_name = parent_state.name
    space_id = parent_state.space_id

    with {:ok, %PersistedAgent{id: parent_id}} <- Persistence.fetch_agent(space_id, parent_name),
         child_name <- generate_unique_name_for_space(space_id),
         attrs <-
           Agent.build_child_attrs(
             parent_state,
             instruction,
             child_name,
             parent_id,
             model_override
           ),
         :ok <- Agent.pre_spawn(attrs),
         {:ok, _pid} <- start_under_supervisor(attrs, child_name),
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
  the model omits it). Resolution rules:
    * an explicit vocation slug is used as-is (refused if not
      whitelisted),
    * otherwise the parent's vocation is used when the space is
      unrestricted or the parent's vocation is whitelisted,
    * otherwise, when the whitelist has exactly one entry, that
      sole allowed vocation is used (a "Head TA may only spawn
      Graders" space works without the model knowing the slug),
    * otherwise (multiple allowed vocations, parent's not among
      them) the spawn is refused as ambiguous.

  `name` must be unique within the space (enforced by the
  `(space_id, name)` composite unique index; a collision
  surfaces as `{:error, :duplicate_name}`).

  Returns `{:ok, name}` on success.
  """
  @spec spawn_agent_in_space(Nest.Agents.Agent.t(), String.t(), String.t() | nil, map() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_agent_in_space(parent_state, name, vocation \\ nil, model_override \\ nil)
      when is_map(parent_state) and is_binary(name) do
    with {:ok, resolved} <- resolve_spawn_vocation(parent_state, vocation),
         :ok <- ensure_spawn_workspace(parent_state, resolved),
         {:ok, %PersistedAgent{id: parent_id}} <-
           Persistence.fetch_agent(parent_state.space_id, parent_state.name),
         :ok <- start_fresh_child(parent_state, name, resolved, parent_id, model_override) do
      {:ok, name}
    end
  end

  # Resolve the effective `vocation_id` for a fresh spawn, applying
  # the blueprint whitelist. See `spawn_agent_in_space/4`'s doc for
  # the resolution rules. Refusals carry the whitelisted vocations
  # (as `{name, slug}` labels) so the caller can tell the model what it
  # may actually spawn.
  defp resolve_spawn_vocation(parent_state, requested) when is_binary(requested) do
    case Vocations.get_by_slug(requested) do
      nil ->
        {:error, {:vocation_not_found, requested}}

      %Vocation{id: id} ->
        allowed = Spaces.spawnable_vocations_for_space(parent_state.space_id)

        if slug_allowed?(allowed, requested) do
          {:ok, id}
        else
          {:error, vocation_error(allowed)}
        end
    end
  end

  defp resolve_spawn_vocation(parent_state, nil) do
    allowed = Spaces.spawnable_vocations_for_space(parent_state.space_id)
    parent_slug = parent_state.vocation.slug

    cond do
      slug_allowed?(allowed, parent_slug) ->
        {:ok, parent_state.vocation_id}

      allowed == nil or allowed == [] ->
        {:ok, parent_state.vocation_id}

      length(allowed) == 1 ->
        resolve_sole_vocation(hd(allowed))

      true ->
        {:error, vocation_error(allowed)}
    end
  end

  # `nil`/`[]` from `spawnable_vocations_for_space/1` mean the
  # space is unrestricted (anything is allowed).
  defp slug_allowed?(nil, _slug), do: true
  defp slug_allowed?([], _slug), do: true
  defp slug_allowed?(allowed, slug), do: slug in allowed

  defp resolve_sole_vocation(slug) do
    case Vocations.get_by_slug(slug) do
      nil -> {:error, {:vocation_not_found, slug}}
      %Vocation{id: id} -> {:ok, id}
    end
  end

  defp vocation_error(allowed) do
    {:vocation_not_spawnable, vocation_labels(allowed)}
  end

  # Resolve the allowed vocation slugs to `{name, slug}` labels for the
  # model-facing error message. Missing/deleted slugs degrade to a
  # placeholder rather than crashing.
  defp vocation_labels(slugs) when is_list(slugs) do
    by_slug = Map.new(Vocations.list_vocations(), &{&1.slug, &1.name})
    Enum.map(slugs, fn slug -> {Map.get(by_slug, slug, "<#{slug}>"), slug} end)
  end

  # Build a fresh-context child's attrs (with `agents-spawn`
  # excluded when the child is at max depth), pre-spawn, start
  # it, and register it in `ChildRegistry`. Kept separate so
  # `spawn_agent_in_space/3` stays under the credo ABC cap.
  defp start_fresh_child(parent_state, name, vocation_id, parent_id, model_override) do
    exclude_spawn = max_depth_reached?(parent_state.depth + 1)

    attrs =
      Agent.SubAgent.build_fresh_child_attrs(
        parent_state,
        name,
        parent_id,
        vocation_id,
        exclude_spawn,
        model_override
      )
      |> Persistence.build_agent_attrs()

    with :ok <- Agent.pre_spawn(attrs),
         {:ok, _pid} <- start_under_supervisor(attrs, name) do
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

      vocation ->
        if Vocations.requires_workspace?(vocation) and is_nil(parent_state.workspace_path) do
          {:error, :workspace_required}
        else
          :ok
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

  # Tell every connected lobby client that `name` was archived so the
  # sidebar can move it into the per-space "Archived" group without a
  # reload. Broadcast for each agent in the subtree (the recursion
  # above archives descendants too), matching `SubAgent`'s
  # `agent:created` notification style.
  defp broadcast_agent_archived(space_id, name) do
    NestWeb.Endpoint.broadcast("lobby", "agent:archived", %{
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
  @spec get_agent(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
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
  end

  defp persistence_list_names_for_space(space_id) do
    Persistence.list_agent_names_for_space(space_id)
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
