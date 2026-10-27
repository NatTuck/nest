defmodule Nest.Agents.Agent.Broadcasts do
  @moduledoc """
  PubSub broadcast helpers for the `Agent` GenServer.

  All broadcasts go through `Phoenix.PubSub` on the per-agent
  topic `"agent:<space_id>:<name>"`. Status broadcasts use the
  wire-format payload produced by `status_payload/1`;
  chat:message and chat:error are simple key-value maps.

  `error/3` and `error/4` are the centralized place that turns
  a server-side error into a `chat:error` event for the UI.
  They also log the error at `:error` level on the server (with
  agent_id, message_index, source location, and a snippet of the
  message) so a server log entry is always paired with a UI
  error banner — the user can paste the `[Source: ...]` line
  from the UI and we can grep the server log for the matching
  stack trace.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Timeline
  alias Nest.Messages.Compaction
  alias Nest.PubSub
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.Info

  # The chunk of the error message that we include in the
  # server log. We log the full message at server side, but
  # truncate the user-facing source tag to keep it copy-pastable.
  @log_snippet_bytes 500

  @doc """
  The per-agent PubSub topic. The single source for the
  `"agent:<space_id>:<name>"` format, so subscribers (`Agent.WaitForIdle`,
  `Agent.Watch`) and broadcasters cannot drift.
  """
  @spec topic(integer(), String.t()) :: String.t()
  def topic(space_id, name), do: "agent:#{space_id}:#{name}"

  @doc """
  The per-space PubSub topic. Frames a lobby client needs for the sidebar
  (agent status, and — since #41 — agent lifecycle) are broadcast here so a
  client only receives them for spaces it is subscribed to; see
  `NestWeb.LobbyChannel`.
  """
  @spec space_topic(integer()) :: String.t()
  def space_topic(space_id), do: "space:#{space_id}"

  @doc """
  The per-space pane topic (issues #119/#120).

  Deliberately **not** `space_topic/1`: `NestWeb.LobbyChannel` subscribes to
  that one, and its unknown-frame clause would take every pane frame and log it
  as a frame it does not know. The pane has its own audience (clients viewing
  an agent in the space, via `NestWeb.AgentChannel`) and its own topic.
  """
  @spec pane_topic(integer()) :: String.t()
  def pane_topic(space_id), do: "space:#{space_id}:pane"

  @doc """
  Announce that a space's pane changed.

  Deliberately a **notification, not a payload**. The decision queue is the
  space's, but a TODO list belongs to one agent, and the per-agent cap means a
  frame holding every agent's list would grow with the number of agents in the
  space. Each subscriber therefore builds its own frame with
  `Nest.Agents.Agent.Pane.payload/2`, naming the agent whose page it is on —
  one atomic read, so the decisions and the `seq` it carries always agree.
  """
  @spec pane(integer()) :: :ok
  def pane(space_id) do
    Phoenix.PubSub.broadcast(PubSub, pane_topic(space_id), {:pane_changed, space_id})
  end

  @doc """
  Announce a newly spawned agent on its space's topic (#41).

  Every lobby channel whose user can see `space_id` subscribes to that
  topic and forwards the frame to its own client, so an agent's name
  reaches exactly the clients that can see its space. The pre-#41 global
  `"lobby"` broadcast reached every connected user, whatever space they
  were in.

  The payload is built here, from `attrs`, rather than by the caller (#72).
  Two callers — the lobby's space-creation path and `Agent.SubAgent`'s spawn
  path — used to build their own maps, so the two shapes could drift while the
  client (`assets/js/store/slices/catalog.js`'s `normalizeAgent/1`) read them
  as one. Every key is present in every frame, so a frame's shape is a property
  of this function and not of which caller sent it; a caller that has nothing
  to say about a field omits it and the field is explicitly `nil` (or the
  documented default) on the wire, rather than absent and indistinguishable
  from a field the client has never been told about.

  `attrs` keys: `:name` (required), `:model`, `:status` (default `"idle"`),
  `:vocation`, `:parent_id`, `:parent_name`, `:depth`
  (default `0`).

  One key is not an attr: `"runningJobs"` is read from the job manager (#175),
  because the count belongs to `Nest.Sandbox.ShellJobs` rather than to whatever
  spawned the agent. A freshly created agent has none, but the key is always
  there, for the same reason as every other.
  """
  @spec agent_created(integer(), keyword()) :: :ok
  def agent_created(space_id, attrs) do
    lifecycle(space_id, :agent_created, created_payload(space_id, attrs))
  end

  @doc false
  # The single construction site for the `agent:created` payload (#72). Public
  # only so a test can pin the shape without going through PubSub.
  @spec created_payload(integer(), keyword()) :: map()
  def created_payload(space_id, attrs) do
    name = Keyword.fetch!(attrs, :name)

    %{
      "name" => name,
      "space_id" => space_id,
      "model" => model_payload(Keyword.get(attrs, :model)),
      "status" => Keyword.get(attrs, :status, "idle"),
      "vocation" => Keyword.get(attrs, :vocation),
      "parentId" => Keyword.get(attrs, :parent_id),
      "parentName" => Keyword.get(attrs, :parent_name),
      "depth" => Keyword.get(attrs, :depth, 0),
      "runningJobs" => running_jobs(space_id, name)
    }
  end

  # How many shell jobs the agent has running (#174/#175). The row is a snapshot
  # of one agent, so this reads that agent's jobs rather than the space's; the
  # live changes arrive as `{:agent_jobs, _}` frames instead, since starting or
  # finishing a job does not change the agent's status.
  #
  # Best-effort, because the manager is a *named* global: a restart between the
  # call and its answer exits the caller with `:noproc`, and this runs in an
  # agent's start path (`SubAgent`) and in a channel's edit. A frame must never
  # be able to fail the process that emits it, and a count is the least important
  # thing on one — `0` is what a row with no manager to ask has.
  defp running_jobs(space_id, name) do
    {space_id, name} |> ShellJobs.list() |> Info.running_count()
  catch
    # Only the manager being *absent* degrades to 0: a call that times out means
    # the manager is wedged, which must surface rather than render as an agent
    # with no jobs.
    :exit, {:noproc, _} -> 0
  end

  @doc """
  Announce that an agent stopped (#73).

  Emitted by the agent itself from `Agent.terminate/2`, so the frame is a fact
  rather than a prediction: `Supervisor.stop_agent/2` fires an exit signal and
  returns, and nothing outside that callback knows the process has actually
  gone. Emitting there also means every way an agent can end is covered — a
  plain stop, an archive, a crash, a reload — because all of them run it.

  One consequence is worth knowing: an archive therefore produces this frame
  *and* `agent:archived`. They do not contradict each other, since an archived
  agent is also stopped, and the client's handler only touches rows still in its
  active list — so a stop that arrives after the archive is a no-op rather than
  a resurrection. See `assets/js/store/slices/catalog.js`'s `markAgentStopped`.

  See `agent_created/2` for the topic and audience.
  """
  @spec agent_stopped(integer(), map()) :: :ok
  def agent_stopped(space_id, payload), do: lifecycle(space_id, :agent_stopped, payload)

  @doc """
  Announce that an agent — and, because archiving recurses, its whole
  subtree — was archived. See `agent_created/2` for the topic and audience.
  """
  @spec agent_archived(integer(), map()) :: :ok
  def agent_archived(space_id, payload), do: lifecycle(space_id, :agent_archived, payload)

  @doc """
  Announce that an agent's model or workspace changed. See
  `agent_created/2` for the topic and audience.
  """
  @spec agent_updated(integer(), map()) :: :ok
  def agent_updated(space_id, payload), do: lifecycle(space_id, :agent_updated, payload)

  defp lifecycle(space_id, tag, payload) do
    Phoenix.PubSub.broadcast(PubSub, space_topic(space_id), {tag, payload})
  end

  def message(state, message) do
    Phoenix.PubSub.broadcast(PubSub, topic(state.space_id, state.name), {:chat_message, message})
  end

  # Broadcast a `chat:error` event AND log the error on the
  # server. Pass `source` (a "Module.function/arity" string)
  # to append a `[Source: ...]` tag to the user-facing message
  # so the UI shows where the error originated.
  def error(space_id, name, message_index, error_msg, source) do
    Timeline.error(space_id, name, error_msg, source)
    tagged = tag_source(error_msg, source)
    log_error(space_id, name, message_index, error_msg, source)
    broadcast_error(space_id, name, message_index, tagged)
  end

  # Backward-compat: callers that don't have a source string
  # fall back to the unsourced form (no `[Source: ...]` tag).
  # Internally still logs at error level so server-side
  # observability isn't lost.
  def error(space_id, name, message_index, error_msg) do
    Timeline.error(space_id, name, error_msg, nil)
    log_error(space_id, name, message_index, error_msg, nil)
    broadcast_error(space_id, name, message_index, error_msg)
  end

  defp broadcast_error(space_id, name, message_index, content) do
    Phoenix.PubSub.broadcast(
      PubSub,
      topic(space_id, name),
      {:chat_error, %{index: message_index, content: content}}
    )
  end

  # Broadcast a `chat:error` event for a compaction failure. The
  # `compactionError: true` marker lets the JS channel handler
  # route the message to `setCompactionError` (which stores the
  # user-facing text on the cache) instead of `setAgentError`
  # (which would flip the connection-level status to "error").
  # The Agent's `chat:status: "compaction_failed"` broadcast
  # immediately after this event drives the banner rendering.
  @doc """
  Broadcast a compaction-failure `chat:error` event. Distinct from
  `error/3,4` because the failure context is agent-level
  (`:compaction_failed` status), not connection-level.
  """
  def compaction_error(state, error_msg, source) do
    tagged = tag_source(error_msg, source)
    log_error(state.space_id, state.name, nil, error_msg, source)
    broadcast_compaction_error(state.space_id, state.name, tagged)
  end

  defp broadcast_compaction_error(space_id, name, content) do
    Phoenix.PubSub.broadcast(
      PubSub,
      topic(space_id, name),
      {:chat_error, %{index: nil, content: content, compactionError: true}}
    )
  end

  @doc """
  Broadcast a `:compaction_loop_detected` event. Distinct from
  `compaction_error/3` because the loop-detection UI shows an
  OK button (clearing the frozen state) instead of the
  compaction-failed Retry button. The marker lets the JS
  channel handler dispatch to the `setCompactionLoop` cache
  action.

  The payload carries the message plus the loop-breaker context
  so the UI can render "tried X of Y times":

      {:chat_compaction_loop,
       %{content: "<reason>\\n[Source: Module.fn/arity]",
         attempt_count: 3, max_attempts: 3}}

  `attempt_count` is the number of consecutive compaction
  attempts that occurred without progress before the loop-breaker
  stopped (equal to `max_attempts` when it trips); `max_attempts`
  is the configured consecutive-compaction limit.
  """
  def compaction_loop(space_id, name, error_msg, source, attempt_count, max_attempts) do
    tagged = tag_source(error_msg, source)
    log_error(space_id, name, nil, error_msg, source)

    Phoenix.PubSub.broadcast(
      PubSub,
      topic(space_id, name),
      {:chat_compaction_loop,
       %{content: tagged, attempt_count: attempt_count, max_attempts: max_attempts}}
    )
  end

  # Append a short, copy-pastable `[Source: Module.fn/arity]`
  # line to the user-facing error message so we can grep the
  # server log for the matching `Logger.error` entry. The
  # newline separator keeps the source visible but distinct
  # from the error text above.
  defp tag_source(error_msg, source) when is_binary(source) and source != "" do
    "#{error_msg}\n[Source: #{source}]"
  end

  defp tag_source(error_msg, _source), do: error_msg

  defp log_error(space_id, name, message_index, error_msg, source) do
    snippet = truncate_for_log(error_msg)

    Logger.error(fn ->
      "[agent:#{space_id}:#{name}] chat:error msg_index=#{message_index} source=#{format_source(source)} :: #{snippet}"
    end)
  end

  defp format_source(source) when is_binary(source) and source != "", do: source
  defp format_source(_other), do: "unknown"

  defp truncate_for_log(msg) when is_binary(msg) do
    if byte_size(msg) > @log_snippet_bytes do
      binary_part(msg, 0, @log_snippet_bytes) <> "...(truncated)"
    else
      msg
    end
  end

  defp truncate_for_log(other), do: inspect(other)

  def status(state) do
    payload = status_payload(state)
    Timeline.status(state, payload)

    Phoenix.PubSub.broadcast(
      PubSub,
      topic(state.space_id, state.name),
      {:chat_status, payload}
    )

    # The sidebar's flat agent list follows status from here: the per-agent
    # topic above only reaches clients *viewing* this agent, so a client
    # would otherwise never learn that another agent went busy (#53).
    Phoenix.PubSub.broadcast(
      PubSub,
      space_topic(state.space_id),
      {:agent_status, %{space_id: state.space_id, name: state.name, status: payload.status}}
    )
  end

  # Broadcast a chat:status event for an agent whose persisted
  # model could not be resolved at startup. Lives in a dedicated
  # sub-module (`Broadcasts.ModelMissing`) so this file stays
  # under the credo 500-line cap.
  defdelegate model_missing(space_id, name, model, reason),
    to: __MODULE__.ModelMissing,
    as: :broadcast

  # Broadcast a chat:status event for an agent whose persisted active
  # sequence failed wire preflight at load (status `:needs_repair`).
  defdelegate needs_repair(space_id, name, violations, repair_command),
    to: __MODULE__.NeedsRepair,
    as: :broadcast

  # Usage totals helpers live in `Broadcasts.Usage` so this file
  # stays under the credo 500-line cap.
  defdelegate empty_usage_totals(), to: __MODULE__.Usage, as: :empty_usage_totals
  defdelegate total_usage(direct, descendant), to: __MODULE__.Usage, as: :total_usage
  defdelegate merge_usage_totals(current, usage), to: __MODULE__.Usage, as: :merge_usage_totals

  # api_log shaping helpers live in `Broadcasts.ApiLog` for the
  # same reason.
  defdelegate next_api_log_id(message_index, sequences),
    to: __MODULE__.ApiLog,
    as: :next_id

  defdelegate api_response_from_run(response),
    to: __MODULE__.ApiLog,
    as: :response_from_run

  # Broadcasts a chat:compaction event after record_compaction.
  # The payload carries the marker only: the archive is never pushed
  # (a long-lived agent's is megabytes), so the frontend re-derives
  # the projections it renders via `chat:history`. The marker gives
  # it the new boundary and the running compaction count.
  def compaction(state, {:compaction, marker}) do
    Phoenix.PubSub.broadcast(
      PubSub,
      topic(state.space_id, state.name),
      {:chat_compaction, %{marker: Compaction.to_json(marker)}}
    )
  end

  def notification(space_id, name, payload) do
    Timeline.notification(space_id, name, payload)
    Phoenix.PubSub.broadcast(PubSub, topic(space_id, name), {:chat_notification, payload})
  end

  # Inbox deltas (issue #27). One frame per queue mutation, describing *that*
  # mutation and nothing else, so the bytes a subscriber pays are proportional
  # to the change rather than to the whole queue:
  #
  #     {:chat_inbox, %{op: "append", messages: [entry], count: n, inboxSeq: s}}
  #     {:chat_inbox, %{op: "remove", ids: [id], count: n, inboxSeq: s}}
  #
  # `count` is the authoritative queue length *after* the mutation. `inboxSeq`
  # is the frame's position in this agent's stream (one per frame, never
  # reused), which is what lets a client tell a contiguous stream from one it
  # fell behind on; the full list — the `init` payload's `inbox` and the
  # `chat:inbox` reply, both `op: "replace"` — is the resync frame. See
  # `Nest.Agents.Agent.Inbox`'s moduledoc for the protocol and its limits.
  @doc """
  Broadcast the entries just appended to the inbox.
  """
  @spec inbox_append(Agent.t(), [map()]) :: Agent.t()
  def inbox_append(state, entries), do: inbox_delta(state, "append", %{messages: entries})

  @doc """
  Broadcast the ids just removed from the inbox.
  """
  @spec inbox_remove(Agent.t(), [String.t()]) :: Agent.t()
  def inbox_remove(state, ids), do: inbox_delta(state, "remove", %{ids: ids})

  # The single construction site for an inbox frame, and the only writer of
  # `live.inbox_seq`: the counter is the number of frames this agent has
  # emitted, so a client that has applied frame `s` knows the next one is
  # `s + 1` and a gap means it missed one (or that the agent restarted, which
  # resets the counter — a *lower* sequence is a gap too, deliberately).
  defp inbox_delta(state, op, payload) do
    seq = state.live.inbox_seq + 1

    Phoenix.PubSub.broadcast(
      PubSub,
      topic(state.space_id, state.name),
      {:chat_inbox, Map.merge(payload, %{op: op, count: length(state.live.inbox), inboxSeq: seq})}
    )

    %{state | live: %{state.live | inbox_seq: seq}}
  end

  # Broadcasts a streaming text delta with character position
  # metadata. The frontend uses `chars_start`/`chars_end` to splice
  # the delta into the assistant message without flicker.
  def delta_text(space_id, name, message_index, content, chars_start) do
    broadcast_delta(space_id, name, %{
      index: message_index,
      content: content,
      chars_start: chars_start,
      chars_end: chars_start + String.length(content),
      part_type: :text
    })
  end

  def delta_thinking(space_id, name, message_index, content, chars_start) do
    broadcast_delta(space_id, name, %{
      index: message_index,
      content: content,
      chars_start: chars_start,
      chars_end: chars_start + String.length(content),
      part_type: :thinking
    })
  end

  # Broadcasts a tool-use start so the JS streaming partial
  # can create a `tool_use` part with the call's id+name
  # before the first arguments fragment arrives. `index` is
  # the LLM content-block index; the Agent's `tool_index_map`
  # uses it to resolve later `:by_index`-keyed deltas to
  # this concrete id.
  def delta_tool_use_start(space_id, name, message_index, id, tool_name, index) do
    broadcast_delta(space_id, name, %{
      index: message_index,
      content: "",
      chars_start: 0,
      chars_end: 0,
      part_type: :tool_use_start,
      tool_call_id: id,
      tool_call_name: tool_name,
      tool_call_block_index: index
    })
  end

  # Broadcasts a tool-use arguments fragment so the JS
  # streaming partial can append to the call's `arguments`.
  # `id` is the concrete tool-call id (resolved from
  # `:by_index` upstream).
  def delta_tool_use_delta(space_id, name, message_index, id, index, fragment) do
    broadcast_delta(space_id, name, %{
      index: message_index,
      content: fragment,
      chars_start: 0,
      chars_end: 0,
      part_type: :tool_use_delta,
      tool_call_id: id,
      tool_call_block_index: index
    })
  end

  defp broadcast_delta(space_id, name, payload) do
    Phoenix.PubSub.broadcast(PubSub, topic(space_id, name), {:chat_delta, payload})
  end

  # Wire-format status payload. Always include the current context_limit
  # and source so the frontend can render the token usage chip without
  # waiting for a separate init / chat:status reply. `usage` carries
  # the running totals (prompt_tokens, completion_tokens, etc.) so the
  # chip numerator updates mid-stream.
  #
  # `context_input_tokens` is computed from the messages list at
  # broadcast time (via `ConversationSize.size/1`) rather than from
  # the cumulative usage_totals map. The latter only knows about
  # the most recent LLM call's per-call fields; the former walks
  # the messages, anchors on the newest assistant's `usage`, then
  # estimates the suffix. This means the chip's
  # numerator reflects the current message list even when no LLM
  # call has happened yet (the suffix is fully estimated) and
  # transitions to API-reported values as the LLM responds.
  #
  # The payload is self-identifying: `name` and `space_id` say whose
  # status this is, so a subscriber to more than one agent's topic can
  # attribute every frame it receives. This is the same identity the
  # space-topic `{:agent_status, …}` frame already carries; a status
  # broadcast that omits it is under-specified.
  #
  # The payload also carries sub-agent identity and usage:
  #
  #   * `parentId` / `parentName` / `depth` — the agent's
  #     tree position. Roots have `parentId: nil,
  #     parentName: nil, depth: 0`. Children carry the
  #     integer `agents.id` of their parent, the parent's
  #     readable name (so the UI's "back to parent" link can
  #     navigate without an extra lookup), and a depth of
  #     `parent.depth + 1`. The JS-side lobby uses these to
  #     render the agent tree (roots at the top, children
  #     indented under their parent).
  #
  #   * `usage` — direct usage (this agent's own LLM calls).
  #     Identical to the previous shape.
  #
  #   * `descendantUsage` — cumulative usage from all
  #     descendants (children, grandchildren, etc.). Same
  #     shape as `usage` but tracked separately so the JS
  #     chip can show the breakdown: direct + descendant =
  #     total.
  #
  #   * `totalUsage` — `usage + descendantUsage`, computed
  #     field-by-field at broadcast time. The chip's "total"
  #     display reads from this; the JS never needs to add
  #     them itself (drift-free).
  defp status_payload(%Nest.Agents.Agent{} = state) do
    live = state.live
    metrics = state.llm_metrics
    direct = metrics.usage_totals
    descendant = metrics.descendant_usage

    %{
      # Every status frame is self-identifying. Without these two keys a
      # subscriber to more than one agent's topic receives
      # `{:chat_status, payload}` frames it cannot tell apart — the same
      # identity the space-topic `{:agent_status, …}` frame already
      # carries (see `status/1` below).
      name: state.name,
      space_id: state.space_id,
      status: to_string(Machine.status_for(live.machine)),
      currentMode: live.mode,
      # The queued-message count rides the status broadcast as well as
      # `chat:inbox`, so a client that missed an inbox frame recovers the count
      # from the next status instead of leaving the panel stale.
      pendingMessageCount: length(live.inbox),
      # The peers this agent still owes a reply to (issue #31 §1.8, decision
      # 15): a status broadcast is the only frame a client sees for a debt
      # that was set or cleared mid-turn, and state the user cannot see is
      # state we are hiding. Always a list — `[]` when nothing is owed — so a
      # missing key can never render as "no debt".
      owedReplies: Machine.owed_senders(live.machine),
      model: model_payload(state.model),
      workspacePath: Mounts.workspace(state.mounts),
      contextLimit: metrics.context_limit,
      contextLimitSource: metrics.context_limit_source,
      parentId: state.tree_position.parent_id,
      parentName: state.tree_position.parent_name,
      depth: state.depth,
      usage:
        __MODULE__.Usage.context_usage_map(
          direct,
          state.chat_state.messages,
          metrics.context_limit,
          live.context_projection
        ),
      descendantUsage: descendant,
      totalUsage: total_usage(direct, descendant)
    }
  end

  # Convert the persisted `model` map to a JSON-safe payload,
  # tolerating either atom or string keys (the persistence layer
  # round-trips through JSON via Ecto's `:map` type). Returns
  # `nil` when the agent has no model so legacy callers don't
  # trip on a missing field.
  defp model_payload(nil), do: nil

  defp model_payload(model) when is_map(model) do
    model
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
