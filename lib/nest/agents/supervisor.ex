defmodule Nest.Agents.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing agent processes.

  Provides functions to start, stop, and list agents. Automatically generates
  unique readable IDs for new agents.

  ## Persistence

  `start_agent/1` upserts the `agents` row alongside the
  in-process start. The agent's pid is returned as soon as
  the in-process start succeeds; the row is the source of
  truth for cross-restart recovery (the in-process `Registry`
  is empty after a BEAM restart).

  `get_agent/1` looks up the pid in the Registry first; if
  no process is running (e.g. the agent was never started in
  this BEAM, or it was started in a previous one), it falls
  back to the persisted row and starts a fresh process
  seeded with the active message history. The DB read
  happens in the calling process, so the agent's `init/1`
  has no DB work and `$callers` walking covers the
  post-restore state.
  """

  use DynamicSupervisor

  require Logger

  alias Nest.Agents.{Agent, NameGenerator, Registry}
  alias Nest.Persistence

  @supervisor_name __MODULE__

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
  Starts a new agent with the given attributes.

  If no ID is provided, generates a unique readable ID.
  If an ID is provided and already exists, returns an error.

  ## Examples

      # Auto-generate ID
      {:ok, "clever-raven"} = Supervisor.start_agent(%{model: %{name: "gpt-4"}})

      # Explicit ID
      {:ok, "my-agent"} = Supervisor.start_agent(%{id: "my-agent", model: %{name: "gpt-4"}})

      # Duplicate ID
      {:error, :already_exists} = Supervisor.start_agent(%{id: "my-agent", model: %{name: "gpt-4"}})

  """
  @spec start_agent(attrs :: map()) :: {:ok, String.t()} | {:error, term()}
  def start_agent(attrs) do
    id = Map.get(attrs, :id) || generate_unique_id()

    case Registry.lookup(id) do
      {:ok, _pid} -> {:error, :already_exists}
      {:error, :not_found} -> start_new(id, attrs)
    end
  end

  # Start a new agent under the supervisor. Pre-fetches the
  # vocation in the calling process (so the agent's `init/1`
  # has no DB work and `$callers` walking covers subsequent
  # writes), then upserts the agent row after a successful
  # in-process start. The upsert failure is logged and
  # non-fatal — the live in-memory agent stays valid; the
  # row exists for cross-restart recovery. Gated on the
  # runtime `:persistence_enabled` flag so test envs skip the
  # DB write entirely.
  defp start_new(id, attrs) do
    attrs =
      attrs
      |> Map.put(:id, id)
      |> Persistence.build_agent_attrs()

    case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
      {:ok, _pid} ->
        upsert_agent_row(id, attrs)
        {:ok, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_agent_row(id, attrs) do
    if persistence_enabled?() do
      case Persistence.upsert_agent(attrs) do
        {:ok, _row} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to upsert agent row for #{id}: #{inspect(reason)}")
      end
    end
  end

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end

  @doc """
  Stops an agent by its ID.

  Returns `:ok` on success, or `{:error, :not_found}` if the agent doesn't exist.

  ## Examples

      :ok = Supervisor.stop_agent("clever-raven")
      {:error, :not_found} = Supervisor.stop_agent("nonexistent")

  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(id) do
    case Registry.lookup(id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor_name, pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all running agent IDs.

  ## Examples

      ["clever-raven", "swift-fox"]

  """
  @spec list_agents() :: list(String.t())
  def list_agents do
    Registry.list()
  end

  @doc """
  Gets the PID of an agent by its ID. Lazily restores the
  agent from the `agents` row when the in-process `Registry`
  has no entry (e.g. right after a BEAM restart, or for a
  brand-new id that's never been started in this BEAM).

  Returns `{:ok, pid}` on success, or `{:error, :not_found}`
  if the id has never been persisted and isn't running.

  ## Examples

      {:ok, pid} = Supervisor.get_agent("clever-raven")
      {:error, :not_found} = Supervisor.get_agent("nonexistent")

  """
  @spec get_agent(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_agent(id) do
    case Registry.lookup(id) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> restore_and_start(id)
    end
  end

  # Restore the agent row from the DB and start a fresh process
  # seeded with the preloaded messages. The DB lookup happens
  # in the calling process so the eventual `start_child`
  # walks `$callers` back to our connection without a
  # per-pid `Sandbox.allow/3`. Persistence disabled → the
  # agent is considered missing.
  defp restore_and_start(id) do
    if persistence_enabled?() do
      case safe_restore_agent(id) do
        {:ok, attrs} -> start_from_attrs(attrs)
        {:ok, :not_found} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp start_from_attrs(attrs) do
    case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort restore. When the DB query fails (no sandboxed
  # connection in non-DataCase tests, transient DB error, etc.)
  # we treat the agent as missing rather than crashing the caller.
  defp safe_restore_agent(id) do
    case Persistence.restore_agent(id) do
      {:ok, attrs} ->
        {:ok, attrs}

      {:error, :not_found} ->
        {:ok, :not_found}

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to restore agent #{id}: #{inspect(reason)}")
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

  defp generate_unique_id do
    existing =
      Registry.list()
      |> MapSet.new()

    NameGenerator.generate_unique(existing)
  end
end
