defmodule Nest.Agents.Agent.ChatTurn.APILog do
  @moduledoc """
  api_log broadcast helpers for the ChatTurn. Each LLM call
  produces a response log (sent after the response), which is
  attached to the assistant message. Request logs are not
  stored — they are synthetic and rebuilt on demand when the
  user expands the API logs widget on a user/tool message.

  The per-message api_log sequence counter is stored in
  the ChatTurn's process dictionary (one ChatTurn per
  process, one counter per process). The counter is
  cleared via `:api_log_sequences_updated` at end-of-turn.

  Extracted from `ChatTurn` to keep the iteration state
  machine under the credo line limit.
  """

  alias Nest.Agents.Agent.Broadcasts

  # The per-message api_log sequence counter. Stored in
  # the ChatTurn's process dictionary (one ChatTurn per
  # process, naturally process-local). The counter is
  # cleared at end-of-turn via :api_log_sequences_updated.
  @api_log_sequences_key :nest_chat_turn_api_log_sequences

  defp get_sequences do
    Process.get(@api_log_sequences_key, %{})
  end

  defp put_sequences(sequences) do
    Process.put(@api_log_sequences_key, sequences)
  end

  @doc """
  Record the response log for the current LLM call. Returns the
  log entry to store on the assistant message (so it is persisted
  with the message, never inserted incomplete). The sequence
  counter lives in the process dict for subsequent calls.
  """
  @spec store_response_log(non_neg_integer(), Nest.LLM.RunResponse.t()) :: map()
  def store_response_log(message_index, response) do
    payload = Broadcasts.api_response_from_run(response)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, get_sequences())
    put_sequences(sequences)

    %{
      id: api_log_id,
      timestamp: DateTime.utc_now(),
      type: :response,
      payload: payload
    }
  end

  @doc """
  Read the current api_log sequences. Sent to the Agent
  at end-of-turn via `{:api_log_sequences_updated, _}`.
  """
  @spec read_sequences() :: map()
  def read_sequences, do: get_sequences()
end
