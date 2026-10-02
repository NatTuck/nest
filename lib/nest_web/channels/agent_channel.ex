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
  alias Nest.Sandbox.ShellJobs
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

  # When a running ChatTurn processes a `chat:stop`, its
  # `ChatTurn.Lifecycle.stop_chat/2` acks this channel (the pid that
  # initiated the stop) with a bare `:stopped`. Nothing needs
  # forwarding: the `chat:stop` handler already replied `:ok`, and the
  # client's "Stopping…" state is cleared by the Agent's subsequent
  # `chat:status: idle` broadcast. We just must not crash on it.
  @impl true
  def handle_info(:stopped, socket), do: {:noreply, socket}

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
  # by `Broadcasts.compaction/2` after a successful
  # `record_compaction` DB write). The payload carries the
  # marker only; the JS side uses it to render the compaction
  # divider and re-fetches the archive projections it shows.
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

  # Handle a background shell-job update from PubSub (broadcast by
  # `Nest.Sandbox.ShellJobs` on start/exit/kill). The payload is the
  # agent's full current job list.
  @impl true
  def handle_info({:shell_jobs, payload}, socket) do
    push(socket, "shell:jobs", payload)
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
      "workspace_path" => agent.workspace_path,
      "messageCount" => length(agent.messages),
      "lastCompactionIndex" => agent.last_compaction_index,
      "compactionCount" => agent.compaction_count,
      "status" => to_string(agent.status),
      "sequenceViolations" => agent.sequence_violations,
      "repairCommand" => agent.repair_command,
      "partial" => build_partial_payload(agent.partial),
      "modes" => agent.modes,
      "defaultMode" => agent.default_mode,
      "currentMode" => agent.current_mode,
      "contextLimit" => agent.context_limit,
      "contextLimitSource" => source_to_string(agent.context_limit_source),
      "usage" => agent.usage,
      "shellJobs" => ShellJobs.list({agent.space_id, agent.name})
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

    case Agents.get_info(space_id, name) do
      {:ok, %{status: status}}
      when status in [
             :compacting,
             :compaction_failed,
             :compaction_loop_detected,
             :context_overflow,
             :model_missing,
             :needs_repair
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

    case Agents.change_model(space_id, name, build_model_map(model_params)) do
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

  # Restart the agent so it re-reads the DB after an offline
  # `mix nest.repair_messages` run. The next `init` push carries the
  # new status: `idle` when the repair worked, `needs_repair` otherwise.
  @impl true
  def handle_in("reload_agent", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.reload_agent(space_id, name) do
      {:ok, _name} -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
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

  # Fetch the agent's current background shell jobs. The same list is
  # pushed as `shell:jobs` whenever it changes; this lets the UI's
  # "Refresh" action (or a freshly joined/reconnected client) request it
  # on demand.
  @impl true
  def handle_in("shell:list", _payload, socket) do
    jobs = ShellJobs.list({socket.assigns.space_id, socket.assigns.name})
    {:reply, {:ok, %{"jobs" => jobs}}, socket}
  end

  # Kill a background shell job from the UI. Scoped to this agent, so a
  # client can't touch another agent's jobs.
  @impl true
  def handle_in("shell:kill", %{"id" => id}, socket) do
    case ShellJobs.kill({socket.assigns.space_id, socket.assigns.name}, id) do
      :ok -> {:reply, {:ok, %{}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{"reason" => "job_not_found"}}, socket}
    end
  end

  # Fetch a job's captured log output for the UI's log viewer.
  #
  # Background-job logs are uncapped on disk (a job may produce output
  # for as long as it runs), but a single websocket frame must stay
  # bounded: the reply carries only the head of the log, with an
  # explicit truncation marker when there is more.
  @shell_log_max_bytes 65_536

  @impl true
  def handle_in("shell:log", %{"id" => id}, socket) do
    case ShellJobs.output({socket.assigns.space_id, socket.assigns.name}, id) do
      {:ok, content} ->
        {:reply, {:ok, %{"content" => bounded_shell_log(content)}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "job_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("chat:status", _payload, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.get_info(space_id, name) do
      {:ok, agent} ->
        reply = %{
          "name" => agent.name,
          "space_id" => agent.space_id,
          "model" => agent.model,
          "messageCount" => agent.message_count,
          "status" => to_string(agent.status),
          "partial" => build_partial_payload(agent.partial),
          "contextLimit" => agent.context_limit,
          "contextLimitSource" => source_to_string(agent.context_limit_source),
          "currentMode" => agent.current_mode,
          "usage" => agent.usage,
          # The archive boundary travels on every status reply so a
          # reconnect that missed a `chat:compaction` broadcast can still
          # reconcile the collapsed-history card (see `setAgentConnected`).
          "lastCompactionIndex" => agent.last_compaction_index,
          "compactionCount" => agent.compaction_count
        }

        {:reply, {:ok, reply}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  # ~64kB soft cap for chat:sync responses — enough headroom for a
  # reasonable batch of messages without blowing past the WebSocket
  # frame layer. Always sends at least one message if any remain.
  @sync_size_limit 65_536

  @impl true
  def handle_in("chat:sync", %{"lastIndex" => last_index}, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.get_agent_sync(space_id, name) do
      {:ok, agent} ->
        serialized =
          agent.messages
          |> Enum.filter(&index_gt?(&1, last_index))
          |> Enum.map(&format_message/1)

        {reply_messages, _} = truncate_by_size(serialized, @sync_size_limit)

        partial = partial_payload(agent.partial, last_index)

        reply = %{
          "messages" => reply_messages,
          "partial" => partial,
          "status" => to_string(agent.status),
          "messageCount" => agent.message_count
        }

        {:reply, {:ok, reply}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "agent_not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("chat:api-logs", %{"index" => index}, socket) do
    space_id = socket.assigns.space_id
    name = socket.assigns.name

    case Agents.get_api_logs(space_id, name, index) do
      {:ok, api_logs} ->
        {:reply, {:ok, %{"apiLogs" => api_logs}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  # Bounds for a single `chat:history` page. The archive holds the
  # whole summarized prefix (thousands of rows for a long-lived agent),
  # so it is only ever read a page at a time; the ceiling keeps a
  # misbehaving client from asking for the lot.
  @history_default_limit 50
  @history_max_limit 200
  @history_roles ~w(system user assistant tool compaction)

  # A page of the agent's archived (pre-compaction) history.
  #
  # The archive is never part of the join payload: for a long-lived
  # agent it is the whole summarized prefix — thousands of rows and
  # megabytes of tool output. The client asks for the rows it is about
  # to render (the collapsed-history card pages through them) and for
  # the two small projections it needs up front (the latest compaction
  # marker, and the user prompts behind the Ctrl/Cmd+Up recall list).
  #
  # This is a pure read against the caller's process, exactly like
  # `chat:api-logs`: the archive lives in the DB, never in agent state,
  # so resolving it here cannot block a live turn.
  @impl true
  def handle_in("chat:history", payload, socket) do
    case history_opts(payload) do
      {:ok, opts} ->
        rows =
          Nest.Persistence.load_history_slice(
            socket.assigns.space_id,
            socket.assigns.name,
            opts
          )

        {:reply, {:ok, %{"messages" => Enum.map(rows, &Message.to_json/1)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}
    end
  end

  # `before` walks backwards through the archive (`nil` starts at the
  # boundary), `limit` bounds one page, and `role` selects a
  # projection — the recall list wants only `user` rows, the card wants
  # every role.
  defp history_opts(payload) do
    with {:ok, before} <- parse_history_before(payload["before"]),
         {:ok, limit} <- parse_history_limit(payload["limit"]),
         {:ok, roles} <- parse_history_role(payload["role"]) do
      {:ok, [before: before, limit: limit, roles: roles]}
    end
  end

  defp parse_history_before(nil), do: {:ok, nil}
  defp parse_history_before(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp parse_history_before(_other), do: {:error, "invalid_before"}

  defp parse_history_limit(nil), do: {:ok, @history_default_limit}

  defp parse_history_limit(n) when is_integer(n) and n > 0,
    do: {:ok, min(n, @history_max_limit)}

  defp parse_history_limit(_other), do: {:error, "invalid_limit"}

  defp parse_history_role(nil), do: {:ok, nil}
  defp parse_history_role(role) when role in @history_roles, do: {:ok, [role]}
  defp parse_history_role(_other), do: {:error, "invalid_role"}

  # Take a prefix of `messages` whose combined JSON wire size is
  # ≤ `limit` bytes. Always returns at least one element when the
  # input is non-empty, regardless of its individual size.
  defp truncate_by_size([first | rest], limit) do
    first_size = json_wire_size(first)

    take_while_under(rest, limit - first_size, [first], first_size)
  end

  defp truncate_by_size([], _limit), do: {[], 0}

  defp take_while_under([], _remaining, acc, total), do: {Enum.reverse(acc), total}

  defp take_while_under([next | rest], remaining, acc, total) do
    next_size = json_wire_size(next)

    if next_size <= remaining do
      take_while_under(rest, remaining - next_size, [next | acc], total + next_size)
    else
      {Enum.reverse(acc), total}
    end
  end

  # Estimate of the JSON byte size for a serialised message map.
  # Uses the external term size of the Jason-encoded binary as a
  # cheap proxy for the actual wire byte count.
  defp json_wire_size(map) when is_map(map) do
    map |> Jason.encode!() |> byte_size()
  end

  # Filter helper for `chat:sync`: keep only messages whose
  # `index` is greater than `last_index`. The `chat_state.messages`
  # list holds `{role, %{index: idx, ...}}` tuples (compaction
  # markers and other non-indexed entries are ignored).
  defp index_gt?({_, %{index: idx}}, last_index), do: idx > last_index
  defp index_gt?(_, _), do: false

  # Build the partial-message payload if the partial is past
  # the client's last seen index; otherwise return nil.
  #
  # `agent.partial` is the already-serialized `Streaming.to_json/1`
  # map, so its keys are strings (`%{"index" => idx}`), not atoms.
  # Matching on `%{index: idx}` here silently failed, so `chat:sync`
  # always replied `partial: nil`; the client then cleared its
  # streaming state on every sync, which turned a delta gap into an
  # endless sync loop (each reply re-created the gap).
  defp partial_payload(%{"index" => idx} = partial, last_index) when idx > last_index do
    build_partial_payload(partial)
  end

  defp partial_payload(_, _), do: nil

  defp format_message(message) do
    Message.to_json(message)
  end

  # Build the model map accepted by `Agents.change_model/3`, preserving
  # the thinking level alongside name/provider.
  defp build_model_map(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider],
      thinking_level: model_params["thinking_level"] || model_params[:thinking_level]
    }
  end

  # A bounded, JSON-safe view of a job's log. Shell output can be raw
  # binary (invalid UTF-8), which `Jason` refuses to encode, so coerce
  # to valid UTF-8 as well as trimming to `@shell_log_max_bytes`.
  defp bounded_shell_log(content) when byte_size(content) <= @shell_log_max_bytes do
    valid_utf8(content)
  end

  defp bounded_shell_log(content) do
    total = byte_size(content)
    head = binary_part(content, 0, @shell_log_max_bytes)

    valid_utf8(head) <>
      "\n... [log truncated: showing first #{@shell_log_max_bytes} of #{total} bytes]"
  end

  # Decode as much valid UTF-8 as possible. `:unicode.characters_to_binary/3`
  # reports the undecodable remainder rather than raising; an invalid byte
  # mid-stream (raw binary output) drops the rest, which is flagged so the
  # omission is visible rather than silent.
  defp valid_utf8(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:error, converted, _rest} -> converted <> "\n... [non-text output omitted]"
      {:incomplete, converted, _rest} -> converted
    end
  end
end
