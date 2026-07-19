defmodule Nest.Agents.Agent.ChatTurn.Messages do
  @moduledoc """
  Message builders for the ChatTurn. Pure functions that
  build the `{:role, %Struct{}}` tuples the ChatTurn
  appends to the Agent. Extracted from `ChatTurn` to
  keep the iteration state machine under the credo line
  limit.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult

  @max_iterations_error_content "Maximum tool iterations reached; cannot execute further tool calls. " <>
                                  "Please provide a final response to the user based on the conversation so far."

  @doc """
  Build an assistant message from a `RunResponse`. The
  Agent stamps the index via `__append_message__/2`.

  Assembles a parts list in the order the response carries
  them: text first, then thinking (with signature), then tool
  uses. Refusal text becomes a `Part.Refusal`. The
  response-level `usage`, `finish_reason`, and `model` are
  preserved on the `Assistant` struct so they round-trip
  through persistence.
  """
  @spec assistant(Nest.LLM.RunResponse.t()) :: {:assistant, Assistant.t()}
  def assistant(response) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: build_assistant_parts(response),
       usage: response.usage,
       finish_reason: response.stop_reason,
       model: response.model,
       api_logs: []
     }}
  end

  defp build_assistant_parts(response) do
    text_part =
      if response.text && response.text != "",
        do: [%Part.Text{text: response.text}],
        else: []

    thinking_part =
      if response.thinking && response.thinking != "",
        do: [%Part.Thinking{thinking: response.thinking, signature: response.thinking_signature}],
        else: []

    tool_use_parts = Enum.map(response.tool_calls || [], &tool_call_to_part/1)

    refusal_part =
      if response.refusal && response.refusal != "",
        do: [%Part.Refusal{refusal: response.refusal}],
        else: []

    text_part ++ thinking_part ++ tool_use_parts ++ refusal_part
  end

  defp tool_call_to_part(%Nest.Messages.ToolCall{} = tc) do
    %Part.ToolUse{id: tc.id, name: tc.name, arguments: tc.arguments || %{}}
  end

  # Wire-format tool calls (plain maps from some clients) — coerce
  # to Part.ToolUse by reading the same fields.
  defp tool_call_to_part(%{"id" => id, "name" => name, "arguments" => args}) do
    %Part.ToolUse{id: id, name: name, arguments: args || %{}}
  end

  defp tool_call_to_part(_other), do: %Part.ToolUse{id: nil, name: "unknown", arguments: %{}}

  @doc """
  Build a `{:tool, _}` message wrapping a list of
  `ToolResult` structs as `Part.ToolResult` parts.
  When `notice_text` is non-nil, it is prepended as a
  `Part.Text` for context/budget warnings that attach
  to the tool response.
  """
  @spec tool([ToolResult.t()], String.t() | nil) :: {:tool, Tool.t()}
  def tool(results, notice_text \\ nil) do
    text_parts = if notice_text, do: [%Part.Text{text: notice_text}], else: []
    result_parts = Enum.map(results, &tool_result_to_part/1)

    {:tool,
     %Tool{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: text_parts ++ result_parts,
       api_logs: []
     }}
  end

  defp tool_result_to_part(%ToolResult{} = tr) do
    %Part.ToolResult{
      tool_call_id: tr.tool_call_id,
      name: tr.name,
      content: tr.content,
      arguments: tr.arguments,
      is_error: tr.is_error || false
    }
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
          arguments: tc.arguments,
          content: @max_iterations_error_content,
          is_error: true
        }
      end)

    tool(error_results)
  end

  @doc """
  Refuse a batch that mixes `context.compact` with other
  tool calls. Returns a single `{:tool, _}` message with one
  `Part.ToolResult` per tool call, all `is_error: true` and a
  shared reason. The LLM receives one refusal message in the
  next iteration and is expected to retry without
  `context.compact` mixed in. Used by `ResponseHandler` when
  the LLM emits `context.compact` together with non-compact
  tool calls.

  `_messages_before` is accepted for symmetry with other
  message builders (it would be used for richer refusal text
  that referenced the pre-swap state); currently unused.
  """
  @spec refuse_context_compact_co_batch([Nest.Messages.ToolCall.t()], [tuple()]) ::
          {:tool, Tool.t()}
  def refuse_context_compact_co_batch(tool_calls, _messages_before) do
    reason =
      "Batch refused: context.compact must be the sole tool in a batch " <>
        "(current batch contains other tools as well). Call context.compact " <>
        "in its own iteration."

    error_results =
      Enum.map(tool_calls, fn tc ->
        %ToolResult{
          tool_call_id: tc.id,
          name: tc.name,
          arguments: tc.arguments,
          content: reason,
          is_error: true
        }
      end)

    tool(error_results)
  end
end
