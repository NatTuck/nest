defmodule Nest.Agents.Agent.Turn.APILog do
  @moduledoc """
  api_log broadcast helpers for the in-process turn driver. Each LLM
  call produces a response log (built after the response), which is
  attached to the assistant message. Request logs are not stored —
  they are synthetic and rebuilt on demand.

  The per-message api_log sequence counter lives on
  `state.live.api_log_sequences` (the Agent owns it now that the turn
  runs in-process).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts

  @doc """
  Record the response log for the current LLM call. Returns
  `{log_entry, new_state}` — the log is attached to the assistant
  message so it persists with it.
  """
  @spec store_response_log(Agent.t(), non_neg_integer(), Nest.LLM.RunResponse.t()) ::
          {map(), Agent.t()}
  def store_response_log(state, message_index, response) do
    payload = Broadcasts.api_response_from_run(response)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, sequences(state))

    log = %{
      id: api_log_id,
      timestamp: DateTime.utc_now(),
      type: :response,
      payload: payload
    }

    {log, put_sequences(state, sequences)}
  end

  defp sequences(state), do: state.live.api_log_sequences

  defp put_sequences(state, sequences) do
    %{state | live: %{state.live | api_log_sequences: sequences}}
  end
end
