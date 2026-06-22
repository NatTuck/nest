defmodule Nest.Agents.Agent.Broadcasts do
  @moduledoc """
  PubSub broadcast helpers for the `Agent` GenServer.

  All broadcasts go through `Phoenix.PubSub` on the per-agent
  topic `"agent:<id>"`. Status broadcasts use the wire-format
  payload produced by `status_payload/1`; chat:message and
  chat:error are simple key-value maps.
  """

  alias Nest.LLM.RunResponse
  alias Nest.Messages.Compaction
  alias Nest.Messages.Message
  alias Nest.PubSub

  def message(agent_id, message) do
    Phoenix.PubSub.broadcast(PubSub, "agent:#{agent_id}", {:chat_message, message})
  end

  def error(agent_id, message_index, error_msg) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{agent_id}",
      {:chat_error, %{index: message_index, content: error_msg}}
    )
  end

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

  # Wire-format status payload. Always include the current context_limit
  # and source so the frontend can render the token usage chip without
  # waiting for a separate init / chat:status reply. `usage` carries
  # the running totals (prompt_tokens, completion_tokens, etc.) so the
  # chip numerator updates mid-stream.
  defp status_payload(%Nest.Agents.Agent{} = state) do
    %{
      status: to_string(state.chat_state.status),
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
