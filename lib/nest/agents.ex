defmodule Nest.Agents do
  @moduledoc """
  Public API for agent management.

  This module provides a high-level interface for creating, managing, and
  interacting with agents. It delegates to the appropriate modules in the
  supervision tree.
  """

  alias Nest.Agents.{Agent, Supervisor}

  @doc """
  Creates a new agent with the given model.

  ## Parameters
  - `model` - A map with `:name` and optionally other model configuration

  ## Returns
  - `{:ok, id}` - Agent created successfully with readable ID
  - `{:error, reason}` - Failed to create agent

  ## Examples

      {:ok, "clever-raven"} = Agents.create_agent(%{name: "gpt-4"})

  """
  @spec create_agent(map()) :: {:ok, String.t()} | {:error, term()}
  def create_agent(model) when is_map(model) do
    Supervisor.start_agent(%{model: model})
  end

  @doc """
  Gets the state of an agent by its ID.

  ## Returns
  - `{:ok, state}` - Agent found with current state
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      {:ok, agent} = Agents.get_agent("clever-raven")
      # agent.id, agent.model, agent.messages, agent.status

  """
  @spec get_agent(String.t()) :: {:ok, Agent.t()} | {:error, :not_found}
  def get_agent(id) do
    case Supervisor.get_agent(id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, Agent.get_state(pid)}
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running agents with their current state.

  Returns a list of maps containing agent information.

  ## Examples

      [%{id: "clever-raven", model: %{name: "gpt-4"}, status: :idle}]

  """
  @spec list_agents() :: list(map())
  def list_agents do
    Supervisor.list_agents()
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
