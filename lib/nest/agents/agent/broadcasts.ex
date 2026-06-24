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

  alias Nest.LLM.RunResponse
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

  # Broadcasts a chat:compaction event after archive_and_compact.
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
    chars_end = chars_start + String.length(content)

    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_delta,
       %{
         index: message_index,
         content: content,
         chars_start: chars_start,
         chars_end: chars_end,
         part_type: :text
       }}
    )
  end

  def delta_thinking(agent_id, message_index, content, chars_start) do
    chars_end = chars_start + String.length(content)

    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_delta,
       %{
         index: message_index,
         content: content,
         chars_start: chars_start,
         chars_end: chars_end,
         part_type: :thinking
       }}
    )
  end

  # Wire-format status payload. Always include the current context_limit
  # and source so the frontend can render the token usage chip without
  # waiting for a separate init / chat:status reply. `usage` carries
  # the running totals (prompt_tokens, completion_tokens, etc.) so the
  # chip numerator updates mid-stream.
  defp status_payload(%Nest.Agents.Agent{} = state) do
    %{
      status: to_string(state.chat_state.status),
      currentMode: state.mode,
      contextLimit: state.llm_metrics.context_limit,
      contextLimitSource: state.llm_metrics.context_limit_source,
      usage: state.llm_metrics.usage_totals
    }
  end

  # Initial / reset state for `usage_totals`. Distinct from the
  # `nil` value the accumulator produces: the agent always has a
  # map, even before the first LLM call has returned.
  #
  # The map carries two axes of state:
  #
  #   * **Per-call (overwrite)** — the most recent LLM call's
  #     values, suitable for "what does the context look like
  #     right now" displays. These are `input_tokens`,
  #     `cache_read_input_tokens`, `cache_creation_input_tokens`,
  #     `last_output`, and the derived `context_input_tokens`.
  #
  #   * **Session (sum)** — cumulative values across every call
  #     the agent has made, suitable for cost estimation and
  #     usage dashboards. These are `output_tokens`,
  #     `total_input_tokens`, `total_cache_read_input_tokens`,
  #     `total_cache_creation_input_tokens`, `total_tokens`, and
  #     `reasoning_tokens`.
  def empty_usage_totals do
    %{
      # Per-call (overwrite)
      input_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      context_input_tokens: 0,
      last_output: 0,
      # Session (sum)
      output_tokens: 0,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      total_tokens: 0,
      reasoning_tokens: 0
    }
  end

  # Combine a fresh usage payload into the running totals.
  #
  # The canonical usage map emitted by both clients uses
  # `:input_tokens` (new / non-cached input for the most recent
  # call), `:cache_read_input_tokens` (served from cache),
  # `:cache_creation_input_tokens` (newly written to cache;
  # Anthropic only), `:output_tokens` (billed output, reasoning
  # included as a subset), and `:reasoning_tokens` (the
  # reasoning subset of output).
  #
  # - `input_tokens`, `cache_read_input_tokens`,
  #   `cache_creation_input_tokens` overwrite (most recent call
  #   is the current state). `context_input_tokens` is derived
  #   as the sum of those three — the real size of the context
  #   window for the most recent call.
  # - `last_output` mirrors the same overwrite semantics for the
  #   assistant turn that just finished.
  # - `total_input_tokens`, `total_cache_read_input_tokens`,
  #   `total_cache_creation_input_tokens`, `output_tokens`,
  #   `total_tokens`, `reasoning_tokens` are summed across the
  #   session. The cost module reads the `total_*` session
  #   fields, not the per-call fields, so it can estimate the
  #   cumulative spend.
  # - A `nil` `usage` is a no-op (callers that don't populate it
  #   shouldn't zero out the running totals).
  def merge_usage_totals(current, nil), do: current

  def merge_usage_totals(current, usage) when is_map(usage) do
    new_call? = Map.has_key?(usage, :input_tokens)

    current
    |> apply_per_call_fields(usage, new_call?)
    |> apply_session_fields(usage)
    |> put_context_input_tokens()
  end

  # Per-call (overwrite) fields. When this usage payload
  # represents a new LLM call (carries `input_tokens`), pull
  # the per-call value from the payload; otherwise preserve the
  # current value. Cache fields default to 0 when the payload
  # omits them (newer providers may report them; older ones
  # don't).
  defp apply_per_call_fields(current, usage, new_call?) do
    Map.merge(current, %{
      input_tokens: per_call_value(usage, :input_tokens, current, new_call?),
      cache_read_input_tokens:
        per_call_value(usage, :cache_read_input_tokens, current, new_call?),
      cache_creation_input_tokens:
        per_call_value(usage, :cache_creation_input_tokens, current, new_call?),
      last_output: per_call_value(usage, :output_tokens, current, new_call?)
    })
  end

  # Session (sum) fields. Each `total_*` field is the running
  # sum of the per-call value across every LLM call. The
  # `per_call_or_zero` helper returns the per-call value when
  # this payload represents a new call, and 0 otherwise, so
  # session totals are preserved on usage-only updates.
  defp apply_session_fields(current, usage) do
    Map.merge(current, %{
      output_tokens: current.output_tokens + per_call_or_zero(usage, :output_tokens),
      total_input_tokens: current.total_input_tokens + per_call_or_zero(usage, :input_tokens),
      total_cache_read_input_tokens:
        current.total_cache_read_input_tokens +
          per_call_or_zero(usage, :cache_read_input_tokens),
      total_cache_creation_input_tokens:
        current.total_cache_creation_input_tokens +
          per_call_or_zero(usage, :cache_creation_input_tokens),
      total_tokens: current.total_tokens + per_call_or_zero(usage, :total_tokens),
      reasoning_tokens: current.reasoning_tokens + per_call_or_zero(usage, :reasoning_tokens)
    })
  end

  # `context_input_tokens` is derived: the per-call sum of the
  # three input fields. Extracted so the merge helpers stay
  # focused on data flow.
  defp put_context_input_tokens(totals) do
    Map.put(
      totals,
      :context_input_tokens,
      totals.input_tokens + totals.cache_read_input_tokens +
        totals.cache_creation_input_tokens
    )
  end

  # For "per-call (overwrite)" fields: when this usage payload
  # represents a new LLM call, use the new value. Otherwise
  # keep the prior value.
  defp per_call_value(usage, key, _current, true),
    do: Map.get(usage, key, 0)

  defp per_call_value(_usage, key, current, false),
    do: Map.get(current, key)

  # For "session (sum)" fields: when the payload represents a
  # new LLM call, add the per-call value to the running total.
  # When it doesn't (e.g. a usage update with only output
  # tokens), add 0 so the running total is preserved.
  defp per_call_or_zero(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, v} when is_integer(v) -> v
      _ -> 0
    end
  end

  def api_log(agent_pid, message_index, api_log_id, api_payload) do
    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_log_id,
         timestamp: DateTime.utc_now(),
         type: :request,
         payload: api_payload
       }}
    )
  end

  def api_response(agent_pid, message_index, api_log_id, api_response) do
    send(
      agent_pid,
      {:api_log, message_index,
       %{
         id: api_log_id,
         timestamp: DateTime.utc_now(),
         type: :response,
         payload: api_response
       }}
    )
  end

  def next_api_log_id(message_index, sequences) do
    sequence = Map.get(sequences, message_index, 0)
    updated_sequences = Map.put(sequences, message_index, sequence + 1)
    id = :io_lib.format("~3..0B.~3..0B", [message_index, sequence]) |> IO.iodata_to_binary()
    {id, updated_sequences}
  end

  def api_response_from_run(%RunResponse{} = response) do
    %{
      role: :assistant,
      content: response.text,
      tool_calls: response.tool_calls,
      tool_results: nil,
      stop_reason: response.stop_reason,
      usage: response.usage
    }
  end
end
