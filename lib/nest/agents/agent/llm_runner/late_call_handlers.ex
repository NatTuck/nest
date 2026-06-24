defmodule Nest.Agents.Agent.LLMRunner.LateCallHandlers do
  @moduledoc """
  End-of-iteration dispatch for the LLM call chain.

  Two paths live here:

    * `build_synthetic_error_pair/3` — when the LLM hits the
      iteration cap and then ignores `tool_choice: :none` on
      the final call, we synthesize error tool results so the
      LLM can see the constraint.

    * `maybe_inject_budget_warning/3` — when the LLM is
      approaching the iteration cap, we inject a system
      reminder into the messages list so it can plan
      accordingly.

  Both helpers are pure (data in, data out). The caller
  (`Nest.Agents.Agent.LLMRunner`) is responsible for
  sending the resulting messages to the GenServer and for
  recursing into the next LLM call.

  Extracted from `LLMRunner` to keep the orchestrator under
  the 500-line credo limit.
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
  Build the `(tool_call_message, tool_result_message, appended_messages)`
  triple for the normal tool-call path. The `tool_results` come from
  `ToolLoop.execute/3` (the BudgetPlanner), which fits / truncates /
  skips each result before persisting it.

  The caller is responsible for sending the two messages to the
  GenServer and recursing into the next LLM call.
  """
  @spec build_tool_pair(
          LLMRunner.RunContext.t(),
          LLMRunner.RunState.t(),
          Nest.LLM.RunResponse.t()
        ) ::
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
  Build a `(tool_call_message, tool_result_message, appended_messages)`
  triple where the tool results carry `is_error: true` and a
  human-readable explanation.

  Used to inject a second-chance tool call when the LLM
  ignores `tool_choice: :none` on the max-iterations final
  call. The caller is responsible for sending the two
  messages to the GenServer and recursing with
  `force_finalize: true`.
  """
  @spec build_synthetic_error_pair(
          LLMRunner.RunContext.t(),
          LLMRunner.RunState.t(),
          Nest.LLM.RunResponse.t()
        ) ::
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
  When the LLM is nearing the iteration cap, append a system
  reminder to the messages list (in order, at the current end).
  The reminder is broadcast to the UI and persisted in
  `state.chat_state.messages` via the `:system_reminder_received`
  GenServer tag.

  Replaces the previous code that mutated `ctx.system_prompt`,
  which (a) broke prompt caching on providers that hash the
  system prompt and (b) failed to actually reach the LLM in
  the wire payload.
  """
  @spec maybe_inject_budget_warning(
          [tuple()],
          LLMRunner.RunContext.t(),
          integer(),
          pid() | nil
        ) :: [tuple()]
  def maybe_inject_budget_warning(messages, _ctx, remaining, _pid)
      when remaining > 2 or remaining <= 0 do
    messages
  end

  def maybe_inject_budget_warning(messages, _ctx, remaining, agent_pid) do
    warning =
      case remaining do
        2 ->
          "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

        1 ->
          "This is your last tool call round. After this, no more tools will be available — provide your final response."
      end

    reminder = {:system, %System{content: warning, timestamp: DateTime.utc_now()}}

    if agent_pid do
      send(agent_pid, {:system_reminder_received, reminder})
    end

    messages ++ [reminder]
  end
end
