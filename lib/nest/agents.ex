defmodule Nest.Agents do
  @moduledoc """
  Public API for agent management.

  This module provides a high-level interface for creating, managing, and
  interacting with agents. It delegates to the appropriate modules in the
  supervision tree.
  """

  alias Nest.Agents.{Agent, Supervisor}
  alias Nest.Vocations

  @doc """
  Creates a new agent with the given model and optional vocation.

  ## Parameters
  - `model` - A map with `:name` and optionally other model configuration
  - `opts` - Optional parameters:
    - `:vocation_id` - ID of the vocation to use
    - `:workspace_path` - Path to the workspace directory

  ## Returns
  - `{:ok, id}` - Agent created successfully with readable ID
  - `{:error, reason}` - Failed to create agent

  ## Examples

      {:ok, "clever-raven"} = Agents.create_agent(%{name: "gpt-4"})
      {:ok, "clever-raven"} = Agents.create_agent(%{name: "gpt-4"}, vocation_id: 1, workspace_path: "/tmp/workspace")

  """
  @spec create_agent(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_agent(model, opts \\ []) when is_map(model) do
    attrs = %{
      model: model,
      vocation_id: Keyword.get(opts, :vocation_id),
      workspace_path: Keyword.get(opts, :workspace_path)
    }

    Supervisor.start_agent(attrs)
  end

  @doc """
  Gets the public info of an agent by its ID.

  ## Returns
  - `{:ok, info}` - Agent found with public info
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      {:ok, info} = Agents.get_info("clever-raven")
      # info.id, info.model, info.message_count, info.status, info.partial

  """
  @spec get_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_info(id) do
    case Supervisor.get_agent(id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, Agent.get_public_info(pid)}
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the full agent state by its ID.

  ## Returns
  - `{:ok, agent}` - Agent found with full state including messages
  - `{:error, :not_found}` - Agent doesn't exist

  """
  @spec get_agent(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_agent(id) do
    case Supervisor.get_agent(id) do
      {:ok, pid} ->
        get_agent_if_alive(pid)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp get_agent_if_alive(pid) do
    if Process.alive?(pid) do
      build_agent_data(pid)
    else
      {:error, :not_found}
    end
  end

  defp build_agent_data(pid) do
    info = Agent.get_public_info(pid)
    messages = Agent.get_messages(pid)
    vocation = get_vocation_info(info.vocation_id)

    agent = %{
      id: info.id,
      model: info.model,
      vocation: vocation,
      messages: messages,
      status: info.status,
      partial: info.partial
    }

    {:ok, agent}
  end

  defp get_vocation_info(nil), do: nil

  defp get_vocation_info(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil -> nil
      v -> %{id: v.id, name: v.name}
    end
  end

  @doc """
  Lists all running agent IDs.

  Returns a list of agent ID strings.

  ## Examples

      ["clever-raven", "swift-fox"]

  """
  @spec list_agents() :: list(String.t())
  def list_agents do
    Supervisor.list_agents()
  end

  @doc """
  Lists public info for all running agents.

  Returns a list of maps containing agent public info.

  ## Examples

      [%{id: "clever-raven", model: %{name: "gpt-4"}, status: :idle, message_count: 0}, ...]

  """
  @spec list_agents_info() :: list(map())
  def list_agents_info do
    list_agents()
    |> Enum.map(&get_info/1)
    |> Enum.filter(fn
      {:ok, info} -> info
      _ -> nil
    end)
    |> Enum.map(fn {:ok, info} -> info end)
  end

  @doc """
  Gets the messages for an agent by its ID.

  ## Returns
  - `{:ok, messages}` - Agent found with messages
  - `{:error, :not_found}` - Agent doesn't exist

  """
  @spec get_messages(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_messages(id) do
    case Supervisor.get_agent(id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, Agent.get_messages(pid)}
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Sends a chat message to an agent.

  The message is added to the agent's history and triggers a streaming
  response from the LLM.

  ## Returns
  - `:ok` - Message sent successfully
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      :ok = Agents.chat("clever-raven", "Hello!")

  """
  @spec chat(String.t(), String.t()) :: :ok | {:error, :not_found}
  def chat(id, content) do
    case Supervisor.get_agent(id) do
      {:ok, pid} ->
        Agent.chat(pid, content)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes an agent by its ID.

  ## Returns
  - `:ok` - Agent deleted successfully
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      :ok = Agents.delete_agent("clever-raven")

  """
  @spec delete_agent(String.t()) :: :ok | {:error, :not_found}
  def delete_agent(id) do
    Supervisor.stop_agent(id)
  end
end
