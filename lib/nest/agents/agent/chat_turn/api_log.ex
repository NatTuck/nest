defmodule Nest.Agents.Agent.ChatTurn.APILog do
  @moduledoc """
  api_log broadcast helpers for the ChatTurn. Each LLM
  call produces a request log (sent before the call)
  and a response log (sent after the response). The
  logs are queued on the Agent's `pending_api_logs` map
  by message_index, then attached to the corresponding
  message when it's appended via
  `Agent.__append_message__/2`.

  Extracted from `ChatTurn` to keep the iteration state
  machine under the credo line limit.
  """

  alias Nest.Agents.Agent.Broadcasts

  @doc """
  Broadcast the request log for the current LLM call.
  Returns the updated state with the new sequence
  number.
  """
  @spec request(map(), non_neg_integer()) :: map()
  def request(state, message_index) do
    request = %Nest.LLM.RunRequest{
      messages: state.messages_snapshot,
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

    payload = Nest.LLM.Runner.format_request_payload(state.ctx.client_config, request, opts)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, state.api_log_sequences)
    Broadcasts.api_log(state.agent_pid, message_index, api_log_id, payload)
    %{state | api_log_sequences: sequences}
  end

  @doc """
  Broadcast the response log for the current LLM call.
  Returns the updated state with the new sequence
  number.
  """
  @spec response(map(), non_neg_integer(), Nest.LLM.RunResponse.t()) :: map()
  def response(state, message_index, response) do
    payload = Broadcasts.api_response_from_run(response)
    {api_log_id, sequences} = Broadcasts.next_api_log_id(message_index, state.api_log_sequences)
    Broadcasts.api_response(state.agent_pid, message_index, api_log_id, payload)
    %{state | api_log_sequences: sequences}
  end
end
