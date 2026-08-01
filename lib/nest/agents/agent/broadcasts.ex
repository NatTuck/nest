defmodule Nest.Agents.Agent.Broadcasts do
  @moduledoc """
  PubSub broadcast helpers for the `Agent` GenServer.

  All broadcasts go through `Phoenix.PubSub` on the per-agent
  topic `"agent:<id>"`. Status broadcasts use the wire-format
  payload produced by `status_payload/1`; chat:message and
  chat:error are simple key-value maps.

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

  alias Nest.Messages.Compaction
  alias Nest.Messages.Message
  alias Nest.PubSub

  # The chunk of the error message that we include in the
  # server log. We log the full message at server side, but
  # truncate the user-facing source tag to keep it copy-pastable.
  @log_snippet_bytes 500

  def message(agent_id, message) do
    Phoenix.PubSub.broadcast(PubSub, "agent:#{agent_id}", {:chat_message, message})
  end

  # Broadcast a `chat:error` event AND log the error on the
  # server. Pass `source` (a "Module.function/arity" string)
  # to append a `[Source: ...]` tag to the user-facing message
  # so the UI shows where the error originated.
  def error(agent_id, message_index, error_msg, source) do
    tagged = tag_source(error_msg, source)
    log_error(agent_id, message_index, error_msg, source)
    broadcast_error(agent_id, message_index, tagged)
  end

  # Backward-compat: callers that don't have a source string
  # fall back to the unsourced form (no `[Source: ...]` tag).
  # Internally still logs at error level so server-side
  # observability isn't lost.
  def error(agent_id, message_index, error_msg) do
    log_error(agent_id, message_index, error_msg, nil)
    broadcast_error(agent_id, message_index, error_msg)
  end

  defp broadcast_error(agent_id, message_index, content) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
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
  def compaction_error(agent_id, error_msg, source) do
    tagged = tag_source(error_msg, source)
    log_error(agent_id, nil, error_msg, source)
    broadcast_compaction_error(agent_id, tagged)
  end

  defp broadcast_compaction_error(agent_id, content) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
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
  """
  def compaction_loop(agent_id, error_msg, source) do
    tagged = tag_source(error_msg, source)
    log_error(agent_id, nil, error_msg, source)

    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_compaction_loop, %{content: tagged}}
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

  defp log_error(agent_id, message_index, error_msg, source) do
    snippet = truncate_for_log(error_msg)

    Logger.error(fn ->
      "[agent:#{agent_id}] chat:error msg_index=#{message_index} source=#{format_source(source)} :: #{snippet}"
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

  def status(agent_id, %Nest.Agents.Agent{} = state) do
    Phoenix.PubSub.broadcast(PubSub, "agent:#{agent_id}", {:chat_status, status_payload(state)})
  end

  def status(agent_id, status) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_status, %{status: to_string(status)}}
    )
  end

  # Broadcast a chat:status event for an agent whose persisted
  # model could not be resolved at startup. Lives in a dedicated
  # sub-module (`Broadcasts.ModelMissing`) so this file stays
  # under the credo 500-line cap.
  defdelegate model_missing(agent_id, model, reason),
    to: __MODULE__.ModelMissing,
    as: :broadcast

  # Usage totals helpers live in `Broadcasts.Usage` so this file
  # stays under the credo 500-line cap.
  defdelegate empty_usage_totals(), to: __MODULE__.Usage, as: :empty_usage_totals
  defdelegate total_usage(direct, descendant), to: __MODULE__.Usage, as: :total_usage
  defdelegate merge_usage_totals(current, usage), to: __MODULE__.Usage, as: :merge_usage_totals

  # api_log send helpers live in `Broadcasts.ApiLog` for the
  # same reason.
  defdelegate api_log(agent_pid, message_index, id, payload),
    to: __MODULE__.ApiLog,
    as: :request

  defdelegate api_response(agent_pid, message_index, id, response),
    to: __MODULE__.ApiLog,
    as: :response

  defdelegate next_api_log_id(message_index, sequences),
    to: __MODULE__.ApiLog,
    as: :next_id

  defdelegate api_response_from_run(response),
    to: __MODULE__.ApiLog,
    as: :response_from_run

  # Broadcasts a chat:compaction event after record_compaction.
  # The frontend uses this to update the local history list (so
  # the CompactionMarker component can render) and to clear the
  # message list back to the LLM's view of the world.
  def compaction(agent_id, {:compaction, marker}, history) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_compaction,
       %{
         marker: Compaction.to_json(marker),
         history: Enum.map(history || [], &Message.to_json/1)
       }}
    )
  end

  def notification(agent_id, payload) do
    Phoenix.PubSub.broadcast(PubSub, "agent:#{agent_id}", {:chat_notification, payload})
  end

  # Broadcasts a streaming text delta with character position
  # metadata. The frontend uses `chars_start`/`chars_end` to splice
  # the delta into the assistant message without flicker.
  def delta_text(agent_id, message_index, content, chars_start) do
    broadcast_delta(agent_id, %{
      index: message_index,
      content: content,
      chars_start: chars_start,
      chars_end: chars_start + String.length(content),
      part_type: :text
    })
  end

  def delta_thinking(agent_id, message_index, content, chars_start) do
    broadcast_delta(agent_id, %{
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
  def delta_tool_use_start(agent_id, message_index, id, name, index) do
    broadcast_delta(agent_id, %{
      index: message_index,
      content: "",
      chars_start: 0,
      chars_end: 0,
      part_type: :tool_use_start,
      tool_call_id: id,
      tool_call_name: name,
      tool_call_block_index: index
    })
  end

  # Broadcasts a tool-use arguments fragment so the JS
  # streaming partial can append to the call's `arguments`.
  # `id` is the concrete tool-call id (resolved from
  # `:by_index` upstream).
  def delta_tool_use_delta(agent_id, message_index, id, index, fragment) do
    broadcast_delta(agent_id, %{
      index: message_index,
      content: fragment,
      chars_start: 0,
      chars_end: 0,
      part_type: :tool_use_delta,
      tool_call_id: id,
      tool_call_block_index: index
    })
  end

  defp broadcast_delta(agent_id, payload) do
    Phoenix.PubSub.broadcast(PubSub, "agent:#{agent_id}", {:chat_delta, payload})
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
  # the messages and uses the last known `tokens` value (which
  # `LLMStreamHandler.mark_last_message_tokens/2` populates) as a
  # floor, then estimates the suffix. This means the chip's
  # numerator reflects the current message list even when no LLM
  # call has happened yet (the suffix is fully estimated) and
  # transitions to API-reported values as the LLM responds.
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
    direct = state.llm_metrics.usage_totals
    descendant = state.llm_metrics.descendant_usage

    %{
      status: to_string(state.chat_state.status),
      currentMode: state.mode,
      model: model_payload(state.model),
      contextLimit: state.llm_metrics.context_limit,
      contextLimitSource: state.llm_metrics.context_limit_source,
      parentId: state.parent_id,
      parentName: state.parent_name,
      depth: state.depth,
      usage:
        Map.put(
          direct,
          :context_input_tokens,
          __MODULE__.Usage.context_input_tokens_for(state.chat_state.messages)
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
