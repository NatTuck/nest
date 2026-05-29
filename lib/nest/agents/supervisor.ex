defmodule Nest.Agents.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing agent processes.

  Provides functions to start, stop, and list agents. Automatically generates
  unique readable IDs for new agents.
  """

  use DynamicSupervisor

  require Logger

  alias Nest.Agents.{Agent, NameGenerator, Registry}

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

    # Check if ID already exists
    case Registry.lookup(id) do
      {:ok, _pid} ->
        {:error, :already_exists}

      {:error, :not_found} ->
        attrs = Map.put(attrs, :id, id)

        case DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs}) do
          {:ok, _pid} ->
            {:ok, id}

          {:error, reason} ->
            {:error, reason}
        end
    end
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
  Returns a list of all running agents with their current state.

  Returns a list of maps containing `:id`, `:model`, and `:status` for each agent.

  ## Examples

      [%{id: "clever-raven", model: %{name: "gpt-4"}, status: :idle}]

  """
  @spec list_agents() :: list(map())
  def list_agents do
    Registry.list()
    |> Enum.map(fn id ->
      case Registry.lookup(id) do
        {:ok, pid} ->
          try do
            state = Agent.get_state(pid)

            %{
              id: id,
              model: state.model,
              status: state.status,
              vocation_id: state.vocation_id,
              mode: state.mode,
              workspace_path: state.workspace_path
            }
          catch
            :exit, _ -> nil
          end

        {:error, :not_found} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets the PID of an agent by its ID.

  Returns `{:ok, pid}` on success, or `{:error, :not_found}` if the agent doesn't exist.

  ## Examples

      {:ok, pid} = Supervisor.get_agent("clever-raven")
      {:error, :not_found} = Supervisor.get_agent("nonexistent")

  """
  @spec get_agent(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_agent(id) do
    Registry.lookup(id)
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
