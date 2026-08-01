defmodule Nest.Agents.Agent.Broadcasts.ApiLog do
  @moduledoc """
  `api_log` send helpers extracted from `Nest.Agents.Agent.Broadcasts`
  so the parent module stays under the credo 500-line cap.

  These functions append entries to the agent's `{:api_log, ...}`
  mailbox so the LLMRunner-recorded wire payloads survive
  server restarts. The `next_api_log_id/2` sequence-number
  bookkeeping is part of `ApiLogs` state; this module only
  shapes the messages the runner sends.
  """

  alias Nest.LLM.RunResponse

  def request(agent_pid, message_index, api_log_id, api_payload) do
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

  def response(agent_pid, message_index, api_log_id, api_response) do
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

  # Sequence-numbered api_log id for a `(message_index,
  # existing_sequences)` pair. The format `<message_index>.<seq>`
  # (zero-padded to 3 digits each) is the canonical format
  # used by both the per-agent apiLog list (see `chat_turn/api_log.ex`)
  # and the API debug page in the JS.
  def next_id(message_index, sequences) do
    sequence = Map.get(sequences, message_index, 0)
    updated_sequences = Map.put(sequences, message_index, sequence + 1)
    id = :io_lib.format("~3..0B.~3..0B", [message_index, sequence]) |> IO.iodata_to_binary()
    {id, updated_sequences}
  end

  # Build the response payload from a `RunResponse`. The shape
  # matches what the api_log render-side render expects:
  # `role: :assistant`, `content: response.text`, tool_call
  # list, and usage. Empty `tool_results` slot is `nil` because
  # the response is downstream of the LLM, not paired with
  # results.
  def response_from_run(%RunResponse{} = response) do
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
