defmodule NestWeb.AgentChannel do
  @moduledoc """
  Channel for real-time chat with a specific agent.

  Handles:
  - Joining agent chat room
  - Sending/receiving chat messages
  - Streaming responses via deltas

  Topic format: "agent:ID" (e.g., "agent:clever-raven")

  Uses Phoenix.PubSub for broadcasting to all connected clients.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Agents

  @impl true
  def join("agent:" <> agent_id, _payload, socket) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        # Subscribe to PubSub topic for this agent
        # All channels connected to this agent will receive broadcasts
        Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

        # Send initial state
        send(self(), {:after_join, agent})

        {:ok, assign(socket, :agent_id, agent_id)}

      {:error, :not_found} ->
        {:error, %{"reason" => "agent not found"}}
    end
  end

  @impl true
  def handle_info({:after_join, agent}, socket) do
    # Build init payload with partial when streaming
    init_payload = %{
      "id" => agent.id,
      "model" => agent.model,
      "vocation" => agent.vocation,
      "messageCount" => length(agent.messages),
      "status" => to_string(agent.status),
      "partial" => build_partial_payload(agent.partial_message)
    }

    push(socket, "init", init_payload)

    {:noreply, socket}
  end

  # Handle chat messages from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_message, message}, socket) do
    push(socket, "chat:message", %{
      "index" => message.index,
      "role" => message.role,
      "content" => message.content,
      "toolCalls" => message[:tool_calls],
      "toolResults" => format_tool_results(message[:tool_results]),
      "thinking" => message[:thinking],
      "usage" => message[:usage],
      "apiLogs" => format_api_logs(message[:api_logs])
    })

    {:noreply, socket}
  end

  # Handle streaming delta from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_delta, delta}, socket) do
    push(socket, "chat:delta", %{
      "index" => delta.index,
      "content" => delta.content,
      "charsStart" => delta.chars_start,
      "charsEnd" => delta.chars_end,
      "partType" => delta.part_type
    })

    {:noreply, socket}
  end

  # Handle errors from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_error, error}, socket) do
    push(socket, "chat:error", %{
      "index" => error.index,
      "content" => error.content
    })

    {:noreply, socket}
  end

  # Handle API call metadata from PubSub (deprecated - now included with messages)
  @impl true
  def handle_info({:api_call, _api_call}, socket) do
    # Deprecated: API calls are now included with messages via apiLogs field
    {:noreply, socket}
  end

  defp build_partial_payload(nil), do: nil

  defp build_partial_payload(partial) do
    %{
      "index" => partial.index,
      "role" => partial.role,
      "content" => partial.content,
      "charsEnd" => partial.chars_sent,
      "timestamp" => partial.timestamp,
      "segments" => partial[:segments] || [],
      "currentType" => partial[:current_type]
    }
  end

  defp format_api_logs(nil), do: []

  defp format_api_logs(api_logs) do
    Enum.map(api_logs, fn log ->
      %{
        "id" => log.id,
        "timestamp" => format_timestamp(log.timestamp),
        "type" => to_string(log.type),
        "payload" => log.payload
      }
    end)
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: other

  defp format_tool_results(nil), do: []

  defp format_tool_results(tool_results) do
    Enum.map(tool_results, fn tr ->
      %{
        "tool_call_id" => tr.tool_call_id,
        "name" => tr.name,
        "content" => extract_tool_result_content(tr.content),
        "is_error" => tr.is_error || false
      }
    end)
  end

  # Extract content from ContentPart structs or plain text
  defp extract_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %LangChain.Message.ContentPart{type: :text, content: text} -> text
      %LangChain.Message.ContentPart{} = part -> inspect(part)
      other -> to_string(other)
    end)
  end

  defp extract_tool_result_content(content), do: to_string(content)

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
        reply = %{
          "id" => agent.id,
          "model" => agent.model,
          "messageCount" => length(agent.messages),
          "status" => to_string(agent.status),
          "partial" => build_partial_payload(agent.partial_message)
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
          "messageCount" => length(agent.messages)
        }

        {:reply, {:ok, reply}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end

  # Cleanup: Unsubscribe from PubSub when channel terminates
  @impl true
  def terminate(_reason, socket) do
    # Only unsubscribe if agent_id was assigned (join completed successfully)
    if agent_id = socket.assigns[:agent_id] do
      Phoenix.PubSub.unsubscribe(Nest.PubSub, "agent:#{agent_id}")
    end

    {:ok, socket}
  end
end
