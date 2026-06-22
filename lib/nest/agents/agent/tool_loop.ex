defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution and budget enforcement for the LLM tool-call
  loop. Called by `Nest.Agents.Agent.LLMRunner` after a response
  with `tool_calls` is received.

  Responsibilities:

    * Build the executor callback that invokes each tool (with a
      special round-trip for the `compact_context` tool that needs
      to mutate the GenServer's state).
    * Run the `BudgetPlanner` to truncate, skip, or pass through
      results based on the per-call budget.
    * Wrap planner results in `Nest.Messages.ToolResult` structs
      for the next LLM turn.
  """

  alias Nest.Agents.Agent.RunContext
  alias Nest.LLM.ToolCall
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.BudgetPlanner
  alias Nest.Tokens.Estimator

  @default_max_fallback 8192
  @compaction_max 256
  @compaction_timeout 60_000
  @budget_reserve 8_192
  @budget_unknown_limit 1_000_000

  @doc """
  Run the tool-call batch through the budget planner and return
  a list of `ToolResult` structs in the same order as the input
  `tool_calls`.

  The `state` argument is unused; it's kept in the signature for
  symmetry with the orchestration call site and for future use.
  """
  @spec execute(RunContext.t(), term(), [ToolCall.t()]) :: [ToolResult.t()]
  def execute(ctx, _state, tool_calls) do
    budget_remaining = compute_remaining_budget(ctx)
    executor = build_tool_executor(ctx)

    BudgetPlanner.execute(tool_calls, executor, budget_remaining, [])
    |> Enum.map(&wrap_result/1)
  end

  defp build_tool_executor(ctx) do
    fn tool_call ->
      case tool_call_name(tool_call) do
        "compact_context" ->
          # The compact_context tool needs to mutate the agent's
          # state.chat_state.messages. The chat task can't do that
          # directly, so it round-trips through the GenServer: send
          # a request, the GenServer runs the compactor, then sends
          # the result back. The chat task blocks on a receive
          # until the result arrives.
          {request_compaction_from_task(ctx, tool_call), @compaction_max}

        _ ->
          raw = LLMTools.execute_one(ctx.tools, tool_call, %{caps: ctx.caps})
          {content, default_max} = tool_result_for(raw, ctx, tool_call)
          {content, default_max || @default_max_fallback}
      end
    end
  end

  defp tool_result_for({:ok, content}, ctx, tool_call) do
    {content, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  defp tool_result_for({:error, reason}, ctx, tool_call) do
    {reason, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  # Round-trip the compaction request through the GenServer. The
  # chat task sends a request, then blocks on a receive for the
  # result. The GenServer runs the compactor (in a Task) and
  # sends the new messages back. The chat task then constructs
  # a synthetic tool result for the LLM.
  defp request_compaction_from_task(ctx, tool_call) do
    focus = get_focus_arg(tool_call)

    send(ctx.agent_pid, {:compact_context_from_task, self(), focus})

    receive do
      {:compact_context_done, new_messages} ->
        "Compacted #{state_messages_count(ctx)} messages into a summary. You now have ~#{estimate_new_working_space(new_messages, ctx.context_limit)} tokens of working space."

      {:compact_context_failed, reason} ->
        "Compaction failed: #{inspect(reason)}"
    after
      @compaction_timeout ->
        "Compaction timed out"
    end
  end

  defp get_focus_arg(tool_call) do
    case tool_call.arguments do
      %{"focus" => f} when is_binary(f) -> f
      _ -> nil
    end
  end

  # Helper for the synthetic tool result string. The "before"
  # count is whatever the chat task is using (we don't have
  # direct access here; just say "messages"). The "after" count
  # is the new length. The "working space" is the recent slice
  # after compaction.
  defp state_messages_count(ctx) do
    length(ctx.messages || [])
  end

  defp estimate_new_working_space(new_messages, context_limit) do
    case context_limit do
      nil ->
        "unknown"

      limit when is_integer(limit) ->
        # Roughly: context_limit minus the new messages size minus
        # the reserve. Just an estimate for the LLM's awareness.
        used = Estimator.estimate_messages(new_messages)
        max(0, limit - used - @budget_reserve)
    end
  end

  # Conservative budget for the tool-result batch. The pre-flight
  # (step 5) will replace this rough estimate with the real one.
  # For now, we charge against the running history and the budget
  # is roughly `context_limit - reserve - estimated_used`. If we
  # don't know the limit, fall back to a large number so the
  # BudgetPlanner effectively passes everything through (degraded
  # behavior — better than over-aggressive truncation).
  defp compute_remaining_budget(ctx) do
    case ctx.context_limit do
      nil -> @budget_unknown_limit
      limit when is_integer(limit) ->
        used = Estimator.estimate_messages(ctx.messages || [])
        max(0, limit - @budget_reserve - used)
    end
  end

  defp wrap_result({tool_call, result_string}) do
    %ToolResult{
      tool_call_id: tool_call.id,
      name: tool_call_name(tool_call),
      content: ensure_non_empty_tool_result(result_string),
      arguments: tool_call_arguments(tool_call),
      is_error: skip_response?(result_string)
    }
  end

  defp tool_call_name(%{name: name}), do: name || "unknown"
  defp tool_call_name(_), do: "unknown"

  defp tool_call_arguments(%{arguments: args}) when is_map(args), do: args
  defp tool_call_arguments(_), do: %{}

  defp skip_response?(content) when is_binary(content) do
    String.starts_with?(content, "[skipped:")
  end

  defp skip_response?(_), do: false

  defp ensure_non_empty_tool_result(""), do: "[no output]"
  defp ensure_non_empty_tool_result(nil), do: "[no output]"
  defp ensure_non_empty_tool_result(s) when is_binary(s), do: s
  defp ensure_non_empty_tool_result(other), do: to_string(other)
end
