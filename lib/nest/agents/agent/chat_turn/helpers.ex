defmodule Nest.Agents.Agent.ChatTurn.Helpers do
  @moduledoc """
  Message-construction helpers for the chat turn's iteration
  coordinator. Pure functions: they take the LLM-bound
  messages list, the response, and the iteration state, and
  return the new messages + the messages-for-next-call
  list. The caller is responsible for sending the messages
  to the Agent and stamping their indices.

  Extracted from `LLMRunner` (where the same functions
  lived as `LateCallHandlers.build_tool_pair/3` and
  `LateCallHandlers.maybe_inject_budget_warning/4`) so the
  iteration coordinator doesn't need to depend on the
  runner module for message construction.
  """

  alias Nest.Agents.Agent.LLMRunner
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  @max_iterations_error_content "Maximum tool iterations reached; cannot execute further tool calls. " <>
                                  "Please provide a final response to the user based on the conversation so far."

  @doc """
  Build the `(tool_call_message, tool_result_message,
  messages_with_pair)` triple for the normal tool-call
  path. The `tool_results` come from `ToolLoop.execute/3`
  (the BudgetPlanner), which fits / truncates / skips each
  result before persisting it.

  The `state.message_index` is the LLMRunner's predicted
  index for the tool call message (the response's index).
  The Agent stamps the actual index when appending; the
  prediction is used here only so the
  `pending_api_logs(message.index)` lookup in the Agent's
  handler finds the response log the LLMRunner stored at
  its predicted index. In the normal case the prediction
  equals the Agent's `next_message_index` so the lookup
  succeeds; in the rare budget-reminder case the
  prediction drifts and the response log is lost (fixed
  in PR 3 by querying the Agent for the next index).

  The `tool_result_message` carries `state.message_index +
  1` as a hint; the Agent's handler reads pending api_logs
  at the LLMRunner's predicted index for the tool
  message, which is the request log for the next LLM
  call.
  """
  @spec build_tool_pair(map(), map(), RunResponse.t()) ::
          {{:assistant, Assistant.t()}, {:tool, Tool.t()}, [tuple()]}
  def build_tool_pair(ctx, state, response) do
    tool_call_message =
      {:assistant,
       %Assistant{
         index: state.message_index,
         timestamp: DateTime.utc_now(),
         content: response.text,
         thinking: response.thinking,
         tool_calls: response.tool_calls,
         # Anthropic's extended-thinking signature, echoed back on
         # subsequent turns. The AnthropicClient reads this field
         # directly when rebuilding assistant content blocks for
         # the next request.
         thinking_signature: response.thinking_signature,
         api_logs: []
       }}

    tool_results =
      ToolLoop.execute(
        ctx,
        state,
        response.tool_calls || []
      )

    tool_result_message =
      {:tool,
       %Tool{
         index: state.message_index + 1,
         timestamp: DateTime.utc_now(),
         tool_results: tool_results,
         api_logs: []
       }}

    {tool_call_message, tool_result_message,
     ctx.messages ++ [tool_call_message, tool_result_message]}
  end

  @doc """
  Build a `(tool_call_message, tool_result_message,
  messages_with_pair)` triple where the tool results carry
  `is_error: true` and a human-readable explanation.

  Used to inject a second-chance tool call when the LLM
  ignores `tool_choice: :none` on the max-iterations
  final call. The caller is responsible for sending the
  two messages to the Agent and recursing with
  `force_finalize: true`.
  """
  @spec build_synthetic_error_pair(map(), map(), RunResponse.t()) ::
          {{:assistant, Assistant.t()}, {:tool, Tool.t()}, [tuple()]}
  def build_synthetic_error_pair(ctx, state, response) do
    tool_calls = response.tool_calls || []

    tool_call_message =
      {:assistant,
       %Assistant{
         index: state.message_index,
         timestamp: DateTime.utc_now(),
         content: response.text,
         thinking: response.thinking,
         tool_calls: tool_calls,
         thinking_signature: response.thinking_signature,
         api_logs: []
       }}

    error_results =
      Enum.map(tool_calls, fn %ToolCall{id: id, name: name} ->
        %ToolResult{
          tool_call_id: id,
          name: name,
          content: @max_iterations_error_content,
          is_error: true
        }
      end)

    tool_result_message =
      {:tool,
       %Tool{
         index: state.message_index + 1,
         timestamp: DateTime.utc_now(),
         tool_results: error_results,
         api_logs: []
       }}

    {tool_call_message, tool_result_message,
     ctx.messages ++ [tool_call_message, tool_result_message]}
  end

  @doc """
  When the LLM is nearing the iteration cap, append a
  system reminder to the messages list (in order, at the
  current end). The reminder is broadcast to the UI and
  persisted in `state.chat_state.messages` via the
  `:system_reminder_received` GenServer tag.

  Replaces the previous code that mutated
  `ctx.system_prompt`, which (a) broke prompt caching on
  providers that hash the system prompt and (b) failed to
  actually reach the LLM in the wire payload.
  """
  @spec maybe_inject_budget_reminder(integer()) :: {:system, System.t()} | nil
  def maybe_inject_budget_reminder(remaining) when remaining > 2 or remaining <= 0, do: nil

  def maybe_inject_budget_reminder(remaining) do
    warning =
      case remaining do
        2 ->
          "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

        1 ->
          "This is your last tool call round. After this, no more tools will be available — provide your final response."
      end

    {:system, %System{content: warning, timestamp: DateTime.utc_now()}}
  end

  @doc false
  # Kept for backward compat with existing tests and any
  # legacy callers. New code should call
  # `maybe_inject_budget_reminder/1` and route the
  # resulting message through the Agent via
  # `GenServer.call({:append_message, _})` rather than
  # relying on the side-effecting `send/2`.
  @spec maybe_inject_budget_warning(
          [tuple()],
          map(),
          integer(),
          pid() | nil
        ) :: [tuple()]
  def maybe_inject_budget_warning(messages, _ctx, remaining, _pid)
      when remaining > 2 or remaining <= 0 do
    messages
  end

  def maybe_inject_budget_warning(messages, _ctx, remaining, agent_pid) do
    case maybe_inject_budget_reminder(remaining) do
      nil ->
        messages

      reminder ->
        if agent_pid do
          send(agent_pid, {:system_reminder_received, reminder})
        end

        messages ++ [reminder]
    end
  end

  @doc false
  # Exposed for tests that need to construct a fake
  # `LLMRunner.RunState` to drive `build_tool_pair/3` and
  # friends. Kept here (rather than in `LLMRunner`) so the
  # helpers don't depend on the runner module.
  def new_state(message_index, active_message_index, max_iterations, api_log_sequences) do
    %LLMRunner.RunState{
      message_index: message_index,
      active_message_index: active_message_index,
      api_log_sequences: api_log_sequences,
      max_iterations: max_iterations,
      force_finalize: false
    }
  end
end
