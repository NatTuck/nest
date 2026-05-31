defmodule NestWeb.LobbyChannel do
  @moduledoc """
  Channel for agent management operations.

  Handles:
  - Listing agents and available models
  - Creating new agents
  - Deleting agents

  Broadcasts agent lifecycle events to all connected clients.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Agents
  alias Nest.Models
  alias Nest.Vocations

  @impl true
  def join("lobby", _payload, socket) do
    # Schedule sending initial state after join completes
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    agents = Agents.list_agents_info()
    models = Models.list()
    vocations = Vocations.list_vocations()

    push(socket, "init", %{agents: agents, models: models, vocations: vocations})
    {:noreply, socket}
  end

  @impl true
  def handle_in("create_agent", %{"model" => model_params} = payload, socket) do
    # Extract model name from params
    model_name = model_params["name"] || model_params[:name]

    # Extract optional vocation_id and workspace_path
    vocation_id = payload["vocation_id"]
    workspace_path = payload["workspace_path"]

    # Build opts for agent creation
    opts =
      []
      |> maybe_add_opt(:vocation_id, vocation_id)
      |> maybe_add_opt(:workspace_path, workspace_path)

    # Create the agent
    case Agents.create_agent(%{name: model_name}, opts) do
      {:ok, id} ->
        # Broadcast to all clients with full agent info
        broadcast(socket, "agent:created", %{
          "id" => id,
          "model" => %{"name" => model_name},
          "vocation_id" => vocation_id,
          "workspace_path" => workspace_path
        })

        {:reply, {:ok, %{"id" => id}}, socket}

      {:error, reason} ->
        Logger.error("Failed to create agent: #{inspect(reason)}")
        {:reply, {:error, %{"reason" => "failed_to_create"}}, socket}
    end
  end

  @impl true
  def handle_in("delete_agent", %{"id" => id}, socket) do
    case Agents.delete_agent(id) do
      :ok ->
        broadcast(socket, "agent:deleted", %{"id" => id})
        {:reply, {:ok, %{}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "not_found"}}, socket}
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
