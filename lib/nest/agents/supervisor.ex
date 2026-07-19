defmodule Nest.Agents.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing agent processes.

  Provides functions to start, stop, and list agents.

  ## Persistence

  `fetch_or_start_agent/1` is the single entry point for
  every caller that wants an agent running. It first looks
  up the row by `name` in `agents`; on `:not_found` it
  inserts a new row, retrying on Postgres `23505`
  unique-name violations with a fresh
  `NameGenerator.generate_unique/1` (passing the in-process
  `Registry` keys combined with `Persistence.list_agent_names/0`
  as the uniqueness `MapSet`).

  When the row exists, the function starts a fresh process
  under the supervisor seeded with the active message
  history; when the row doesn't yet exist, it inserts the
  row first, then starts the process.

  The DB read (and insert) happens in the calling process so
  the agent's `init/1` has no DB work and `$callers` walking
  covers the post-startup message-write path.

  `get_agent/1` keeps the **on-demand-load** semantics: the
  agent row, all active messages, and the vocation are not
  loaded at boot. They are loaded the first time
  `get_agent/1` is called and the in-process `Registry`
  misses.

  The loading itself is **eager**:
  `Persistence.build_attrs_for_start/1` materializes the
  full active message list and the `Vocation` struct in a
  single round-trip. The Agent's `init/1` then composes the
  system prompt and (idempotently) re-inserts the system
  message at index 0 — the unique constraint on
  `(agent_id, message_index)` makes that re-insert a no-op
  when the row was loaded from the DB. See
  `Init.persist_initial_system_message/1` for the contract.
  """

  use DynamicSupervisor

  require Logger

  alias Nest.Agents.{Agent, ChildRegistry, NameGenerator, Registry}
  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence

  @supervisor_name __MODULE__

  @max_insert_attempts 5

  # Client API

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
  Fetch or start the agent with the given attrs.

  The DB is the source of truth for "does this name exist?":

    * If the row exists in `agents`, start a fresh process
      under the supervisor seeded with the active
      `messages` (and the persisted `:vocation`,
      `:workspace_path`, `:next_message_index`). Returns
      `{:ok, name}`.
    * If no row exists, generate a unique `name` (when the
      caller didn't supply one), insert a new row, then
      start a fresh process. Returns `{:ok, name}`.
    * If the row insert races a concurrent insert with the
      same `name` (Postgres `23505`), regenerate the `name`
      and retry, up to `@max_insert_attempts` times.
    * Persistence disabled in test/env: fall through to
      the in-process `Registry`. If the agent is already
      running, return its name; if not, start a process
      and return its name.

  The runtime `:persistence_enabled` config (see
  `config/test.exs`) is the only knob; production runs
  with persistence enabled.

  ## Examples

      {:ok, "clever-raven"} = Supervisor.fetch_or_start_agent(%{model: %{name: "gpt-4"}})
      {:ok, "my-agent"}    = Supervisor.fetch_or_start_agent(%{name: "my-agent", model: %{name: "gpt-4"}})
  """
  @spec fetch_or_start_agent(map()) :: {:ok, String.t()} | {:error, term()}
  def fetch_or_start_agent(attrs) do
    if persistence_enabled?() do
      do_fetch_or_start_with_persistence(attrs)
    else
      do_fetch_or_start_no_persistence(attrs)
    end
  end

  # Path A — persistence enabled. DB lookup is the source
  # of truth; the in-process `Registry` is a running-cache.
  defp do_fetch_or_start_with_persistence(attrs) do
    name = Map.get(attrs, :name)

    case name do
      nil ->
        initial_name = generate_unique_name()
        do_insert_and_start(Map.put(attrs, :name, initial_name), @max_insert_attempts)

      existing_name ->
        case safe_fetch_for_start(existing_name) do
          {:ok, start_attrs} ->
            start_under_supervisor(start_attrs, existing_name)

          {:error, :not_found} ->
            # The caller asked for an explicit name that has no
            # DB row. We have no model/vocation/workspace_path to
            # insert with. Returning `:not_found` keeps the
            # contract clean: `fetch_or_start_agent/1` is "look
            # up or start one" — only the no-name path (used by
            # `create_agent/2`) creates a new row, and it
            # supplies a fully-formed attrs map.
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Try inserting the row, retrying with a fresh name on
  # `:duplicate_name`. After all attempts are exhausted,
  # return `:could_not_generate_unique_name`.
  defp do_insert_and_start(attrs, attempts_remaining) do
    attrs = Persistence.build_agent_attrs(attrs)

    case Persistence.insert_agent(attrs) do
      {:ok, _row} ->
        start_under_supervisor(attrs, attrs.name)

      {:error, :duplicate_name} when attempts_remaining > 1 ->
        new_attrs = Map.put(attrs, :name, generate_unique_name())
        do_insert_and_start(new_attrs, attempts_remaining - 1)

      {:error, :duplicate_name} ->
        {:error, :could_not_generate_unique_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Best-effort fetch_for_start. When the DB query fails
  # (no sandboxed connection in non-DataCase tests,
  # transient DB error, etc.) we return the failure
  # rather than crashing the caller.
  defp safe_fetch_for_start(name) do
    case Persistence.build_attrs_for_start(name) do
      {:ok, attrs} ->
        {:ok, attrs}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Failed to fetch agent #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Path B — persistence disabled. The in-process
  # `Registry` is the only source of truth; new agents get
  # an adjective-animal name.
  defp do_fetch_or_start_no_persistence(attrs) do
    name = Map.get(attrs, :name) || generate_unique_name()

    case Registry.lookup(name) do
      {:ok, _pid} ->
        {:ok, name}

      {:error, :not_found} ->
        # The caller either asked for an explicit name
        # that's not running yet, or they let us generate
        # one. Either way, start a fresh process under
        # that name. Without a DB we have no collision
        # guard beyond the in-process `Registry`, but the
        # `start_under_supervisor/2` `{:already_started,
        # _pid}` clause surfaces genuine races as a
        # graceful `{:ok, name}`.
        attrs = attrs |> Map.put(:name, name) |> Persistence.build_agent_attrs()
        start_under_supervisor(attrs, name)
    end
  end

  # Start a fresh process under the supervisor. Idempotent:
  # if the Registry already has the name (a parallel start
  # raced), treat as success.
  defp start_under_supervisor(attrs, name) do
    case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Test-only: start a single agent under the supervisor
  by raw attrs and return its pid. Used by tests that
  want the agent as a child of the application's
  `DynamicSupervisor` (so `Supervisor.stop_agent/1`'s
  cascade walk can terminate it via
  `DynamicSupervisor.terminate_child/2`).

  Production code uses `fetch_or_start_agent/1` or
  `start_agent_with_parent/2`; this helper exists for
  test setup only.
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
  child gets a fresh `agents` row with `parent_id =
  parent_state.parent_id` (the parent's integer `agents.id`,
  resolved via `Persistence.fetch_agent_by_name/1` against
  the parent's `name`) and `depth = parent_state.depth + 1`.

  The child's runtime carries `parent_name = parent_state.name`
  so the child can dispatch messages back to the parent via
  `Nest.Agents.Registry.via_tuple/1` without an additional
  integer→name lookup at completion time.

  Messages: a copy of `parent_state.chat_state.messages` is
  passed via `:preloaded_messages`. The child's
  `Init.persist_initial_system_message/1` re-inserts the
  system row idempotently under the `(agent_id,
  message_index)` unique constraint, and the rest of the
  preloaded sequence round-trips into the child's
  `state.chat_state.messages`. Each child has its own
  integer `agents.id`, so the rows are independent —
  `agents.parent_id` is the only cross-agent relationship
  in the `messages` table.

  Returns `{:ok, child_name}` on success. The caller is
  responsible for kicking off the child's chat turn via
  `Agents.chat(child_name, instruction)` (the supervisor
  does not start the turn itself — that would couple spawn
  to message delivery and break unit tests that want a
  spawned-but-idle child).
  """
  @spec start_agent_with_parent(Nest.Agents.Agent.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_agent_with_parent(parent_state, instruction)
      when is_map(parent_state) and is_binary(instruction) do
    parent_name = parent_state.name

    with {:ok, %PersistedAgent{id: parent_id}} <- Persistence.fetch_agent_by_name(parent_name),
         child_name <- generate_unique_name(),
         attrs <-
           build_child_attrs(parent_name, parent_id, parent_state, child_name, instruction),
         {:ok, _row} <- Persistence.insert_agent(attrs),
         {:ok, _pid} <- start_under_supervisor(attrs, child_name),
         :ok <- ChildRegistry.register(parent_name, child_name) do
      {:ok, child_name}
    end
  end

  defp build_child_attrs(parent_name, parent_id, parent_state, child_name, _instruction) do
    %{
      name: child_name,
      model: parent_state.model,
      # Children inherit the parent's vocation (so they get
      # the same prompt, tools, modes). The
      # `SystemPrompt.compose_vocation_config/4` depth filter
      # strips `clone_agent` from the tool list when at max
      # depth; the parent's `parent_id`/`depth` columns
      # produce the same effect for the child's prompt.
      vocation_id: parent_state.vocation_id,
      vocation: parent_state.vocation,
      workspace_path: parent_state.workspace_path,
      parent_id: parent_id,
      parent_name: parent_name,
      depth: parent_state.depth + 1,
      preloaded_messages: parent_state.chat_state.messages,
      last_compaction_index: Map.get(parent_state.chat_state, :last_compaction_index, -1),
      next_message_index: parent_state.chat_state.next_message_index,
      initial_api_log_sequences: %{}
    }
  end

  @doc """
  Stops an agent by its `name`. Cascade-walks the
  `ChildRegistry`: any registered children (and their
  grandchildren, recursively) are stopped first, then the
  named agent. This keeps the runtime tree consistent when
  a parent is removed via the lobby's `delete_agent`
  handle_in.

  Returns `:ok` on success (children cleaned up; parent
  terminated when present). Returns `{:error,
  :not_found}` when the named agent isn't running and
  has no registered children — i.e., the call had
  nothing to do.

  ## Examples

      :ok = Supervisor.stop_agent("clever-raven")
      {:error, :not_found} = Supervisor.stop_agent("nonexistent")
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(name) do
    # Cascade first, by name only. The `ChildRegistry`
    # self-cleans via DOWN monitors; we don't rely on its
    # entries being consistent during the walk.
    children = ChildRegistry.children_of(name)

    if children == [] do
      stop_one(name)
    else
      for child_name <- children, do: _ = stop_agent(child_name)
      stop_one(name)
    end
  end

  defp stop_one(name) do
    case Registry.lookup(name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor_name, pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Cascade-walk `name`'s registered children and terminate
  each subtree, WITHOUT terminating `name` itself. The
  agent's own `terminate/2` calls this so the runtime
  tree is consistent when a parent is torn down via the
  supervisor (we don't double-terminate).

  Best-effort: each child's `terminate/2` cascades its
  own subtree through this same helper. A child's monitor
  clearing happens via `ChildRegistry`'s `:DOWN` handler
  so the parent's bookkeeping stays accurate.
  """
  @spec cascade_children_only(String.t()) :: :ok
  def cascade_children_only(name) do
    children = ChildRegistry.children_of(name)

    for child_name <- children do
      _ = stop_agent(child_name)
    end

    :ok
  end

  @doc """
  Returns a list of all running agent `name`s.

  ## Examples

      ["clever-raven", "swift-fox"]
  """
  @spec list_agents() :: list(String.t())
  def list_agents do
    Registry.list()
  end

  @doc """
  Get the pid of an agent by its `name`. Tries the
  in-process `Registry` first, then falls back to
  `fetch_or_start_agent/1` (which inserts a row for an
  existing name or starts a fresh process for a known
  name).

  Returns `{:ok, pid}` on success, or
  `{:error, :not_found}` if the name has never been
  persisted and isn't running in this BEAM.

  ## Examples

      {:ok, pid} = Supervisor.get_agent("clever-raven")
      {:error, :not_found} = Supervisor.get_agent("nonexistent")
  """
  @spec get_agent(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_agent(name) do
    case Registry.lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        # On-demand load. With persistence enabled, ask the
        # DB-backed path; the caller might be asking for a
        # name that exists in another BEAM. Without
        # persistence, the in-process `Registry` is the
        # only source of truth and the answer is always
        # `:not_found`.
        on_demand_load(name)
    end
  end

  defp on_demand_load(name) do
    if persistence_enabled?() do
      do_on_demand_load_with_persistence(name)
    else
      {:error, :not_found}
    end
  end

  defp do_on_demand_load_with_persistence(name) do
    case fetch_or_start_agent(%{name: name}) do
      {:ok, ^name} ->
        Registry.lookup(name)

      {:ok, _other} ->
        # The retry path collided. The supervisor's
        # `insert_agent` returned a different name than the
        # caller asked for; that's a server error from the
        # caller's perspective, not a missing agent.
        {:error, :name_collision}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Server Callbacks

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1000
    )
  end

  # Private Functions

  # Generate a unique agent name against the combined
  # in-process `Registry` keys and the DB-resident names.
  # The DB names reduce (but do not eliminate) the
  # probability of a Postgres `23505` race; the retry
  # loop in `do_insert_and_start/2` handles the rare
  # collision case explicitly.
  defp generate_unique_name do
    existing_names = Registry.list() ++ persistence_list_names()
    NameGenerator.generate_unique(MapSet.new(existing_names))
  end

  defp persistence_list_names do
    if persistence_enabled?() do
      try do
        Persistence.list_agent_names()
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
