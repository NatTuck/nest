defmodule Nest.Agents.Agent.ChatTurn.APILog do
  @moduledoc """
  api_log broadcast helpers for the ChatTurn. Each LLM
  call produces a request log (sent before the call)
  and a response log (sent after the response). The
  logs are queued on the Agent's `pending_api_logs` map
  by message_index, then attached to the corresponding
  message when it's appended via
  `Agent.__append_message__/2`.

  The per-message api_log sequence counter is stored in
  the ChatTurn's process dictionary (one ChatTurn per
  process, one counter per process). The counter is
  cleared via `:api_log_sequences_updated` at end-of-turn.

  Extracted from `ChatTurn` to keep the iteration state
  machine under the credo line limit.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.LLM.Runner

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
  Broadcast the request log for the current LLM call.
  Returns `:ok` (the counter lives in the process dict).
  """
  @spec request(map(), non_neg_integer(), list()) :: :ok
  def request(state, message_index, messages) do
    request = %Nest.LLM.RunRequest{
      messages: messages,
      tools: state.ctx.tools,
      tool_choice: state.ctx.tool_choice,
      model: state.ctx.client_config.model,
      stream: true,
      metadata: %{}
    }

    opts = [
      base_url: state.ctx.client_config.base_url,
      api_key: state.ctx.client_config.api_key,
      receive_timeout: state.ctx.client_config.receive_timeout,
      agent_pid: state.ctx.agent_pid
    ]

    payload = Runner.format_request_payload(state.ctx.client_config, request, opts)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, get_sequences())
    put_sequences(sequences)
    Broadcasts.api_log(state.ctx.agent_pid, message_index, api_log_id, payload)
    :ok
  end

  @doc """
  Broadcast the response log for the current LLM call.
  Returns the updated sequences map (also stored in the
  process dict for subsequent calls).
  """
  @spec response(map(), non_neg_integer(), Nest.LLM.RunResponse.t()) :: map()
  def response(state, message_index, response) do
    payload = Broadcasts.api_response_from_run(response)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, get_sequences())
    put_sequences(sequences)
    Broadcasts.api_response(state.ctx.agent_pid, message_index, api_log_id, payload)
    sequences
  end

  @doc """
  Read the current api_log sequences. Sent to the Agent
  at end-of-turn via `{:api_log_sequences_updated, _}`.
  """
  @spec read_sequences() :: map()
  def read_sequences, do: get_sequences()
end
