defmodule Nest.Agents.Agent.ChatTurn.Messages do
  @moduledoc """
  Message builders for the ChatTurn. Pure functions that
  build the `{:role, %Struct{}}` tuples the ChatTurn
  appends to the Agent. Extracted from `ChatTurn` to
  keep the iteration state machine under the credo line
  limit.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult

  @max_iterations_error_content "Maximum tool iterations reached; cannot execute further tool calls. " <>
                                  "Please provide a final response to the user based on the conversation so far."

  @doc """
  Build an assistant message from a `RunResponse`. The
  Agent stamps the index via `__append_message__/2`.
  """
  @spec assistant(Nest.LLM.RunResponse.t()) :: {:assistant, Assistant.t()}
  def assistant(response) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       content: response.text,
       thinking: response.thinking,
       thinking_signature: response.thinking_signature,
       tool_calls: response.tool_calls,
       refusal: response.refusal,
       api_logs: []
     }}
  end

  @doc """
  Build a `{:tool, _}` message wrapping a list of
  `ToolResult` structs.
  """
  @spec tool([ToolResult.t()]) :: {:tool, Tool.t()}
  def tool(results) do
    {:tool,
     %Tool{
       index: nil,
       timestamp: DateTime.utc_now(),
       tool_results: results,
       api_logs: []
     }}
  end

  @doc """
  Build a synthetic error tool-result message for the
  max-iterations second-chance path. The LLM hit the
  iteration cap and emitted more tool calls; the
  ChatTurn synthesizes error results so the LLM sees
  the constraint on the next call.
  """
  @spec synthetic_error_tool_results(Nest.LLM.RunResponse.t()) :: {:tool, Tool.t()}
  def synthetic_error_tool_results(response) do
    error_results =
      Enum.map(response.tool_calls || [], fn tc ->
        %ToolResult{
          tool_call_id: tc.id,
          name: tc.name,
          content: @max_iterations_error_content,
          arguments: tc.arguments,
          is_error: true
        }
      end)

    tool(error_results)
  end
end
