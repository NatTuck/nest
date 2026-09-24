defmodule Nest.Agents.Agent.Broadcasts.ApiLog do
  @moduledoc """
  Response-log shaping helpers extracted from
  `Nest.Agents.Agent.Broadcasts` so the parent module stays under
  the credo 500-line cap.

  The response log is stored on the assistant message itself (and
  therefore persisted with it); these functions only build the id
  and payload that go into that stored entry.
  """

  alias Nest.LLM.RunResponse

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
