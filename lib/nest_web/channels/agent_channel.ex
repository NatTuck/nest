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
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming

  @impl true
  def join("agent:" <> agent_id, _payload, socket) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        # Subscribe to PubSub topic for this agent
        # All channels connected to this agent will receive broadcasts
        Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

        # Send initial state via handle_info. The init is published
        # to the test's mailbox as a socket push. Tests use
        # `assert_push "init"` with a generous timeout (the init is
        # the first event after the channel is established).
        send(self(), {:after_join, agent})

        {:ok, assign(socket, :agent_id, agent_id)}

      {:error, :not_found} ->
        {:error, %{"reason" => "agent not found"}}
    end
  end

  @impl true
  def handle_info({:after_join, agent}, socket) do
    init_payload = %{
      "id" => agent.id,
      "model" => agent.model,
      "vocation" => agent.vocation,
      "messageCount" => length(agent.messages),
      "history" => Enum.map(agent.history || [], &Message.to_json/1),
      "status" => to_string(agent.status),
      "partial" => build_partial_payload(agent.partial),
      "modes" => agent.modes,
      "defaultMode" => agent.default_mode,
      "currentMode" => agent.current_mode,
      "contextLimit" => agent.context_limit,
      "contextLimitSource" => source_to_string(agent.context_limit_source),
      "usage" => agent.usage
    }

    push(socket, "init", init_payload)

    {:noreply, socket}
  end

  # Handle chat messages from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_message, message}, socket) do
    push(socket, "chat:message", Message.to_json(message))

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

  # Handle status changes from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_status, status_payload}, socket) do
    push(socket, "chat:status", status_payload)

    {:noreply, socket}
  end

  # Handle notifications from PubSub (broadcast by Agent)
  @impl true
  def handle_info({:chat_notification, payload}, socket) do
    push(socket, "chat:notification", payload)

    {:noreply, socket}
  end

  # Handle API log metadata from PubSub (deprecated - now included with messages)
  @impl true
  def handle_info({:api_log, _api_log}, socket) do
    # Deprecated: API logs are now included with messages via apiLogs field
    {:noreply, socket}
  end

  defp build_partial_payload(nil), do: nil

  defp build_partial_payload(%Streaming.AssistantAccumulator{} = acc) do
    Streaming.to_json(acc)
  end

  # The context_limit_source is an internal atom (`:config`, `:vllm`,
  # etc.) that survives the JSON wire trip as a string. Convert
  # up-front so the test assertions and the frontend payload agree
  # on shape.
  defp source_to_string(nil), do: nil
  defp source_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp source_to_string(other), do: other

  defp format_message(message) do
    Message.to_json(message)
  end

  @impl true
  def handle_in("chat:message", %{"content" => content} = payload, socket) do
    agent_id = socket.assigns.agent_id
    mode = Map.get(payload, "mode")

    case Agents.chat(agent_id, content, mode) do
      :ok ->
        {:reply, {:ok, %{}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end

  # User clicked Stop on the chat page. The reply is
  # immediate (`{:ok, %{}}`); the actual stop finalization
  # happens asynchronously when the chat task unwinds and the
  # agent's `handle_info({:chat_stopped, _}, _)` finalizes
  # the partial accumulator. The client uses its own local
  # "stopping" state to render the button as "Stopping..."
  # until the next `chat:status` push arrives.
  @impl true
  def handle_in("chat:stop", _payload, socket) do
    agent_id = socket.assigns.agent_id

    case Agents.stop_chat(agent_id, self()) do
      :ok -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
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
          "partial" => build_partial_payload(agent.partial),
          "contextLimit" => agent.context_limit,
          "contextLimitSource" => source_to_string(agent.context_limit_source),
          "currentMode" => agent.current_mode,
          "usage" => agent.usage
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
        new_messages =
          agent.messages
          |> Enum.filter(&index_gt?(&1, last_index))
          |> Enum.map(&format_message/1)

        partial = partial_payload(agent.partial, last_index)

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

  # Filter helper for `chat:sync`: keep only messages whose
  # `index` is greater than `last_index`. The `chat_state.messages`
  # list holds `{role, %{index: idx, ...}}` tuples (compaction
  # markers and other non-indexed entries are ignored).
  defp index_gt?({_, %{index: idx}}, last_index), do: idx > last_index
  defp index_gt?(_, _), do: false

  # Build the partial-message payload if the partial is past
  # the client's last seen index; otherwise return nil.
  defp partial_payload(%{index: idx} = partial, last_index) when idx > last_index do
    build_partial_payload(partial)
  end

  defp partial_payload(_, _), do: nil

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
