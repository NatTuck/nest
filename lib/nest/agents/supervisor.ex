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

  `get_agent/1` keeps the lazy-restore semantics: it
  consults the `Registry` first, and falls through to
  `fetch_or_start_agent/1` (which inserts a row for an
  existing name or starts a fresh process for a known
  name) when the in-process `Registry` doesn't have the
  agent.
  """

  use DynamicSupervisor

  require Logger

  alias Nest.Agents.{Agent, NameGenerator, Registry}
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

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end

  @doc """
  Stops an agent by its `name`.

  Returns `:ok` on success, or `{:error, :not_found}` if the
  agent doesn't exist.

  ## Examples

      :ok = Supervisor.stop_agent("clever-raven")
      {:error, :not_found} = Supervisor.stop_agent("nonexistent")
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(name) do
    case Registry.lookup(name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor_name, pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
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
        # Lazy-restore. With persistence enabled, ask the
        # DB-backed path; the caller might be asking for a
        # name that exists in another BEAM. Without
        # persistence, the in-process `Registry` is the
        # only source of truth and the answer is always
        # `:not_found`.
        lazy_restore(name)
    end
  end

  defp lazy_restore(name) do
    if persistence_enabled?() do
      do_lazy_restore_with_persistence(name)
    else
      {:error, :not_found}
    end
  end

  defp do_lazy_restore_with_persistence(name) do
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
