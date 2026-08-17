defmodule NestWeb.AgentChannel do
  @moduledoc """
  Channel for real-time chat with a specific agent.

  Handles:
  - Joining agent chat room
  - Sending/receiving chat messages
  - Streaming responses via deltas

  Topic format: `"agent:<space_id>:<name>"` (e.g.
  `"agent:1:clever-raven"`). The space_id and name are
  parsed from the topic on join and used as the
  authoritative identity for every backend call.

  Uses Phoenix.PubSub for broadcasting to all connected clients.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Agents
  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming
  alias Nest.Spaces

  @impl true
  def join("agent:" <> rest, _payload, socket) do
    current_user = socket.assigns.current_user

    with {:ok, space_id, name} <- parse_topic(rest),
         :ok <- ensure_space_active(space_id),
         {:ok, agent} <- Agents.get_agent(space_id, name),
         :ok <- authorize_join(space_id, name, current_user) do
      joined_join(space_id, name, agent, current_user, socket)
    else
      {:error, :bad_topic} ->
        {:error, %{"reason" => "bad_topic"}}

      {:error, :not_found} ->
        {:error, %{"reason" => "agent not found"}}

      {:error, :forbidden} ->
        {:error, %{"reason" => "forbidden"}}

      {:error, :space_archived} ->
        {:error, %{"reason" => "space_archived"}}

      {:error, reason} ->
        Logger.warning("agent:#{rest} channel join failed: #{inspect(reason)}")
        {:error, %{"reason" => "agent_unavailable"}}
    end
  end

  defp joined_join(space_id, name, agent, current_user, socket) do
    # NOTE: we deliberately do NOT call `Phoenix.PubSub.subscribe/2`
    # here. Phoenix.Channel.Server.init_join/3 already subscribes the
    # channel process to the channel topic on every join. Because
    # Phoenix.PubSub does not deduplicate subscriptions, an explicit
    # subscribe here would register this process a SECOND time and
    # every broadcast (e.g. `chat:delta`) would be delivered twice —
    # doubling streamed deltas. Let Phoenix own the subscription.
    send(self(), {:after_join, agent})

    socket =
      socket
      |> assign(:space_id, space_id)
      |> assign(:name, name)
      |> assign(:current_user, current_user)

    {:ok, socket}
  end

  # `agent:<space_id>:<name>` — split on the first two
  # colons. A name with a colon would be unusual, but the
  # DB schema allows it; we keep the parse tolerant so
  # names like `dm:1` round-trip correctly.
  defp parse_topic(rest) do
    case String.split(rest, ":", parts: 2) do
      [space_id_str, name] ->
        case Integer.parse(space_id_str) do
          {space_id, ""} -> {:ok, space_id, name}
          _ -> {:error, :bad_topic}
        end

      _ ->
        {:error, :bad_topic}
    end
  end

  # Allow the join when the user owns the agent or the agent
  # is shared. `Agent.get_public_info/1` is the source of truth
  # for ownership and visibility — the runtime state carries
  # the same fields the DB row does, so this avoids a separate
  # `fetch_agent/2` round-trip.
  defp authorize_join(space_id, name, current_user) do
    case Agents.Registry.lookup(space_id, name) do
      {:ok, pid} ->
        info = Nest.Agents.Agent.get_public_info(pid)
        authorize_from(info, current_user)

      _ ->
        # The supervisor's on-demand loader can hydrate an
        # agent that's not currently in the Registry. Fall
        # back to a DB lookup for that case.
        case Nest.Persistence.fetch_agent(space_id, name) do
          {:ok, %PersistedAgent{} = row} -> authorize_from(row, current_user)
          {:error, :not_found} -> {:error, :not_found}
        end
    end
  end

  # An archived space cannot be joined for chat. Even an owner
  # must inspect it from the archived-spaces view rather than
  # talk to its agents, which are stopped on archive. A space
  # with no row at all falls through to the `get_agent` path,
  # which surfaces the normal `:not_found`.
  defp ensure_space_active(space_id) do
    case Spaces.get_space(space_id) do
      %Nest.Spaces.Space{archived: true} -> {:error, :space_archived}
      _ -> :ok
    end
  end

  # Shared predicate for both runtime + persisted rows. The
  # schema field name `created_by_user_id` matches the runtime
  # state field name, so we can destructure either uniformly.
  defp authorize_from(%{created_by_user_id: id, shared: shared}, current_user)
       when id == current_user.id or shared == true,
       do: :ok

  defp authorize_from(%PersistedAgent{created_by_user_id: id, shared: shared}, current_user)
       when id == current_user.id or shared == true,
       do: :ok

  defp authorize_from(_other, _current_user), do: {:error, :forbidden}

  @impl true
  def handle_info({:after_join, agent}, socket) do
    push(socket, "init", build_init_payload(agent))
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
      "partType" => delta.part_type,
      # Tool-use fields; only present on `part_type:
      # :tool_use_start` / `:tool_use_delta`. Omitted
      # otherwise so the wire payload stays minimal for the
      # hot text/thinking path.
      "toolCallId" => delta[:tool_call_id],
      "toolCallName" => delta[:tool_call_name],
      "toolCallBlockIndex" => delta[:tool_call_block_index]
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

  # Handle a `chat:compaction` event from PubSub (broadcast
  # by `Broadcasts.compaction/3` after a successful
  # `record_compaction` DB write). The payload carries
  # the marker and the full archived history; the JS side
  # uses it to render the compaction divider in the UI.
  @impl true
  def handle_info({:chat_compaction, payload}, socket) do
    push(socket, "chat:compaction", payload)
    {:noreply, socket}
  end

  # Handle a `chat:compaction-loop` event from PubSub (broadcast
  # by `Broadcasts.compaction_loop/3` when the loop-breaker
  # trips). The JS side stores the text via `setCompactionLoop`
  # so the StatusBanner renders the OK button.
  @impl true
  def handle_info({:chat_compaction_loop, payload}, socket) do
    push(socket, "chat:compaction-loop", payload)
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

  defp build_init_payload(agent) do
    %{
      "name" => agent.name,
      "space_id" => agent.space_id,
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
  end

  defp build_partial_payload(nil), do: nil

  defp build_partial_payload(%Streaming.AssistantAccumulator{} = acc) do
    Streaming.to_json_safe(acc)
  end

  # `agent.partial` arrives here already JSON-serialized from
  # `Nest.Agents.Agent.IntrospectionHandler.build_public_info/1`
  # (which runs `Streaming.to_json_safe/1` before returning the
  # info map). Pass through unchanged — running it through
  # `to_json_safe/1` again would error because the `defimpl
  # Jason.Encoder` is only defined for `%AssistantAccumulator{}`,
  # not for plain maps.
  defp build_partial_payload(%{} = payload), do: payload

  # The context_limit_source is an internal atom (`:config`, `:vllm`,
  # etc.) that survives the JSON wire trip as a string. Convert
  # up-front so the test assertions and the frontend payload agree
  # on shape.
  defp source_to_string(nil), do: nil
  defp source_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp source_to_string(other), do: other

  @impl true
  def handle_in("chat:message", %{"content" => content} = payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name
    mode = Map.get(payload, "mode")

    case Agents.get_agent(space_id, name) do
      {:ok, %{status: status}}
      when status in [
             :compacting,
             :compaction_failed,
             :compaction_loop_detected,
             :context_overflow,
             :model_missing
           ] ->
        {:reply, {:error, %{"reason" => "agent_status_#{status}"}}, socket}

      {:ok, %{status: status}} when status in [:streaming, :executing_tools] ->
        {:reply, {:error, %{"reason" => "agent_busy"}}, socket}

      {:ok, _agent} ->
        case Agents.chat(space_id, name, content, mode) do
          :ok ->
            {:reply, {:ok, %{}}, socket}

          {:error, :not_found} ->
            {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
        end

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("change_model", %{"model" => model_params}, socket)
      when is_map(model_params) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name
    new_name = model_params["name"] || model_params[:name]
    new_provider = model_params["provider"] || model_params[:provider]

    case Agents.change_model(space_id, name, %{name: new_name, provider: new_provider}) do
      :ok ->
        {:reply, {:ok, %{}}, socket}

      {:error, :agent_busy} ->
        {:reply, {:error, %{"reason" => "agent_busy"}}, socket}

      {:error, {:invalid_model, _reason}} ->
        {:reply, {:error, %{"reason" => "invalid_model"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}

      {:error, reason} ->
        Logger.warning("change_model failed on agent:#{space_id}:#{name}: #{inspect(reason)}")

        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("change_model", _payload, socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  @impl true
  def handle_in("chat:retry-compaction", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.retry_compaction(space_id, name) do
      :ok -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("chat:loop-detected-ok", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.compaction_loop_detected_ok(space_id, name) do
      :ok -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("chat:stop", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.stop_chat(space_id, name, self()) do
      :ok -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("chat:status", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.get_agent(space_id, name) do
      {:ok, agent} ->
        reply = %{
          "name" => agent.name,
          "space_id" => agent.space_id,
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

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("chat:sync", %{"lastIndex" => last_index}, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.get_agent(space_id, name) do
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

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
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

  defp format_message(message) do
    Message.to_json(message)
  end
end
