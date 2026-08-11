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
  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Spaces

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

  Returns `{:ok, name}` on success.
  """
  @spec fetch_or_start_agent(integer(), map()) :: {:ok, String.t()} | {:error, term()}
  def fetch_or_start_agent(space_id, attrs) do
    if persistence_enabled?() do
      do_fetch_or_start_with_persistence(space_id, attrs)
    else
      do_fetch_or_start_no_persistence(space_id, attrs)
    end
  end

  defp do_fetch_or_start_with_persistence(space_id, attrs) do
    case Map.get(attrs, :name) do
      nil ->
        {:error, :not_found}

      existing_name ->
        case safe_fetch_for_start(space_id, existing_name) do
          {:ok, start_attrs} -> start_under_supervisor(start_attrs, existing_name)
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
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

  defp do_fetch_or_start_no_persistence(space_id, attrs) do
    name = Map.get(attrs, :name) || generate_unique_name_for_space(space_id)

    case Registry.lookup(space_id, name) do
      {:ok, _pid} ->
        {:ok, name}

      {:error, :not_found} ->
        attrs = attrs |> Map.put(:name, name) |> Persistence.build_agent_attrs()
        start_under_supervisor(attrs, name)
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
  """
  @spec start_under_test(map()) :: {:ok, pid()} | {:error, term()}
  def start_under_test(attrs) do
    _name = Map.fetch!(attrs, :name)

    case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end

  @doc """
  Spawn a child agent as a descendant of `parent_state`. The
  child inherits `parent_state.space_id` so cascade-termination
  scoped to that space will find it.
  """
  @spec start_agent_with_parent(Nest.Agents.Agent.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_agent_with_parent(parent_state, instruction)
      when is_map(parent_state) and is_binary(instruction) do
    parent_name = parent_state.name
    space_id = parent_state.space_id

    with {:ok, %PersistedAgent{id: parent_id}} <- Persistence.fetch_agent(space_id, parent_name),
         child_name <- generate_unique_name_for_space(space_id),
         attrs <- Agent.build_child_attrs(parent_state, instruction, child_name, parent_id),
         :ok <- Agent.pre_spawn(attrs),
         {:ok, _pid} <- start_under_supervisor(attrs, child_name),
         :ok <- ChildRegistry.register(space_id, parent_name, child_name) do
      {:ok, child_name}
    end
  end

  @doc """
  Spawn a fresh-context sub-agent in the coordinator's space.

  Unlike `start_agent_with_parent/2` (which forks the parent's
  message history and registers the child in `ChildRegistry`
  so the parent tracks its completion), this creates an
  *independent* specialist: system-prompt-only context, no
  `ChildRegistry` link, `depth: 0`. The coordinator just asks
  for the specialist to exist in the space.

  The spawn is authorized against the space's blueprint
  `spawnable_vocation_ids` whitelist: an unrestricted space
  (no blueprint, or empty list) allows any `vocation_id`;
  otherwise `vocation_id` must be whitelisted.

  `name` must be unique within the space (enforced by the
  `(space_id, name)` composite unique index; a collision
  surfaces as `{:error, :duplicate_name}`).

  Returns `{:ok, name}` on success.
  """
  @spec spawn_agent_in_space(Nest.Agents.Agent.t(), String.t(), integer()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn_agent_in_space(parent_state, name, vocation_id)
      when is_map(parent_state) and is_binary(name) and is_integer(vocation_id) do
    with :ok <- authorize_spawn(parent_state.space_id, vocation_id) do
      Nest.Agents.create_agent(
        parent_state.space_id,
        parent_state.model,
        name: name,
        vocation_id: vocation_id,
        created_by_user_id: parent_state.created_by_user_id,
        shared: parent_state.shared
      )
    end
  end

  # Enforce the space's blueprint spawnable-vocation whitelist.
  # `nil` (no blueprint / missing blueprint) and `[]` both mean
  # unrestricted; a non-empty list is a strict whitelist.
  defp authorize_spawn(space_id, vocation_id) do
    case Spaces.spawnable_vocation_ids_for_space(space_id) do
      nil -> :ok
      [] -> :ok
      ids -> if vocation_id in ids, do: :ok, else: {:error, :vocation_not_spawnable}
    end
  end

  @doc """
  Stops an agent by its `{space_id, name}`. Cascade-walks
  the `ChildRegistry` for descendants in the same space.
  """
  @spec stop_agent(integer(), String.t()) :: :ok | {:error, :not_found}
  def stop_agent(space_id, name) do
    for child_name <- ChildRegistry.children_of(space_id, name),
        do: _ = stop_agent(space_id, child_name)

    stop_one(space_id, name)
  end

  defp stop_one(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        Process.exit(pid, :shutdown)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Cascade-walk `name`'s registered children in `space_id`
  and terminate each subtree, WITHOUT terminating `name`
  itself.
  """
  @spec cascade_children_only(integer(), String.t()) :: :ok
  def cascade_children_only(space_id, name) do
    children = ChildRegistry.children_of(space_id, name)

    for child_name <- children do
      _ = stop_agent(space_id, child_name)
    end

    :ok
  end

  @doc """
  Get the pid of an agent by its `{space_id, name}`.
  """
  @spec get_agent(integer(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_agent(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        on_demand_load(space_id, name)
    end
  end

  defp on_demand_load(space_id, name) do
    if persistence_enabled?() do
      do_on_demand_load_with_persistence(space_id, name)
    else
      {:error, :not_found}
    end
  end

  defp do_on_demand_load_with_persistence(space_id, name) do
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
    existing_names =
      Registry.list_for_space(space_id) ++ persistence_list_names_for_space(space_id)

    NameGenerator.generate_unique(MapSet.new(existing_names))
  end

  defp persistence_list_names_for_space(space_id) do
    if persistence_enabled?() do
      try do
        Persistence.list_agent_names_for_space(space_id)
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      []
    end
  end
end
