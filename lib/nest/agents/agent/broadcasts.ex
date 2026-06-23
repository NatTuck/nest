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
  def empty_usage_totals do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      reasoning_tokens: 0,
      last_output: 0
    }
  end

  # Combine a fresh usage payload into the running totals.
  #
  # The canonical usage map emitted by both clients uses
  # `:input_tokens` (the size of the full context for that call)
  # and `:output_tokens` (the tokens just generated). Providers
  # may also surface `:reasoning_tokens` (Anthropic, o1-style
  # OpenAI) and `:cache_read_input_tokens` / `:cache_creation_input_tokens`
  # (Anthropic).
  #
  # - `input_tokens` overwrites, not adds: it is the size of the
  #   full context for that call, so the most recent value is
  #   the current context size.
  # - `last_output` mirrors the same overwrite semantics for the
  #   assistant turn that just finished.
  # - `output_tokens`, `total_tokens`, `reasoning_tokens` are
  #   summed across the session.
  # - A `nil` `usage` is a no-op (callers that don't populate it
  #   shouldn't zero out the running totals).
  def merge_usage_totals(current, nil), do: current

  def merge_usage_totals(current, usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens)
    output = Map.get(usage, :output_tokens, 0)
    total = Map.get(usage, :total_tokens, 0)
    reasoning = Map.get(usage, :reasoning_tokens, 0)

    %{
      input_tokens: if(input != nil, do: input, else: current.input_tokens),
      output_tokens: current.output_tokens + output,
      total_tokens: current.total_tokens + total,
      reasoning_tokens: current.reasoning_tokens + reasoning,
      last_output: if(input != nil, do: output, else: current.last_output)
    }
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
