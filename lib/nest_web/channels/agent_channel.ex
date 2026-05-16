defmodule NestWeb.AgentChannel do
  @moduledoc """
  Channel for real-time chat with a specific agent.

  Handles:
  - Joining agent chat room
  - Sending/receiving chat messages
  - Streaming responses via deltas

  Topic format: "agent:ID" (e.g., "agent:clever-raven")
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Agents

  @impl true
  def join("agent:" <> agent_id, _payload, socket) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        # Set the channel PID on the agent for callbacks
        {:ok, pid} = Agents.Supervisor.get_agent(agent_id)
        Nest.Agents.Agent.set_channel(pid, self())

        # Send initial state
        send(self(), {:after_join, agent})

        {:ok, assign(socket, :agent_id, agent_id)}

      {:error, :not_found} ->
        {:error, %{"reason" => "agent not found"}}
    end
  end

  @impl true
  def handle_info({:after_join, agent}, socket) do
    push(socket, "init", %{
      "id" => agent.id,
      "model" => agent.model,
      "messages" => agent.messages,
      "status" => agent.status
    })

    {:noreply, socket}
  end

  # Handle messages from the agent process
  @impl true
  def handle_info({:delta, content}, socket) do
    broadcast!(socket, "chat:delta", %{"content" => content})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:message, message}, socket) do
    broadcast!(socket, "chat:message", %{
      "role" => message.role,
      "content" => message.content
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("chat:message", %{"content" => content}, socket) do
    agent_id = socket.assigns.agent_id

    case Agents.chat(agent_id, content) do
      :ok ->
        {:reply, {:ok, %{}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:history", _payload, socket) do
    agent_id = socket.assigns.agent_id

    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        {:reply, {:ok, %{"messages" => agent.messages}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end
end
