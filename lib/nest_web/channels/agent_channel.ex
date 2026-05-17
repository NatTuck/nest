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
    # Calculate last complete message index
    last_complete_index =
      if agent.messages != [] do
        List.last(agent.messages).index
      else
        -1
      end

    # Build lightweight init payload (no messages sent)
    init_payload = %{
      "id" => agent.id,
      "model" => agent.model,
      "lastCompleteIndex" => last_complete_index,
      "status" => to_string(agent.status)
    }

    push(socket, "init", init_payload)

    {:noreply, socket}
  end

  # Handle streaming delta from the agent process
  @impl true
  def handle_info({:delta, delta}, socket) do
    # Update partial message in agent state (handled by Agent GenServer)
    # Just broadcast the delta to all subscribers
    broadcast!(socket, "chat:delta", %{
      "index" => delta.index,
      "content" => delta.content,
      "charsStart" => delta.chars_start,
      "charsEnd" => delta.chars_end
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:error, error}, socket) do
    broadcast!(socket, "chat:error", %{
      "index" => error.index,
      "content" => error.content
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:message_complete, message}, socket) do
    broadcast!(socket, "chat:message", %{
      "index" => message.index,
      "role" => message.role,
      "content" => message.content
    })

    {:noreply, socket}
  end

  defp build_partial_payload(nil), do: nil

  defp build_partial_payload(partial) do
    %{
      "index" => partial.index,
      "role" => partial.role,
      "content" => partial.content,
      "charsSent" => partial.chars_sent,
      "timestamp" => partial.timestamp
    }
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
  def handle_in("chat:status", _payload, socket) do
    agent_id = socket.assigns.agent_id

    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        last_complete_index =
          if agent.messages != [] do
            List.last(agent.messages).index
          else
            -1
          end

        reply = %{
          "id" => agent.id,
          "model" => agent.model,
          "lastCompleteIndex" => last_complete_index,
          "status" => to_string(agent.status)
        }

        {:reply, {:ok, reply}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:sync", %{"lastIndex" => last_index}, socket) do
    agent_id = socket.assigns.agent_id

    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        # Get last complete index
        last_complete_index =
          if agent.messages != [] do
            List.last(agent.messages).index
          else
            -1
          end

        # Get messages after last_index
        new_messages =
          Enum.filter(agent.messages, fn msg -> msg.index > last_index end)

        # Check if there's a partial message being streamed
        partial =
          if agent.partial_message && agent.partial_message.index > last_index do
            build_partial_payload(agent.partial_message)
          else
            nil
          end

        reply = %{
          "messages" => new_messages,
          "partial" => partial,
          "status" => to_string(agent.status),
          "lastCompleteIndex" => last_complete_index
        }

        {:reply, {:ok, reply}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end
end
