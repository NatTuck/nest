defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by `Nest.Agents.Agent.ChatTurn` after a response
  with `tool_calls` is received. Responsibilities:

    * Intercept `context.compact` (solo) and route it through
      the existing compaction request flow (round-trips through
      the Agent GenServer).
    * Refuse the entire batch if `context.compact` is co-batched
      with other tools. The LLM must retry with a singleton
      context.compact batch.
    * Delegate general batches to `Nest.Agents.Agent.BatchSizer`,
      which handles preflight + execute + keep-or-summarize.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.Estimator

  @compaction_timeout 60_000
  @budget_reserve 8_192

  @doc """
  Run a tool-call batch. Returns a list of `ToolResult`
  structs in input order.

  The `state` argument is unused; kept in the signature for
  symmetry with the call site.
  """
  @spec execute(map(), term(), [ToolCall.t()]) :: [ToolResult.t()]
  def execute(ctx, _state, tool_calls) do
    cond do
      tool_calls == [] ->
        []

      context_compact_solo?(tool_calls) ->
        [handle_solo_context_compact(ctx, hd(tool_calls))]

      contains_context_compact?(tool_calls) ->
        refuse_context_compact_co_batch(tool_calls)

      true ->
        BatchSizer.run(tool_calls, ctx)
    end
  end

  # `context.compact` is special: it round-trips through the
  # Agent GenServer (which owns the compactor lifecycle). The
  # tool result is the post-compaction status string.
  defp context_compact_solo?([%ToolCall{name: "context", arguments: %{"action" => "compact"}}]),
    do: true

  defp context_compact_solo?(_), do: false

  defp contains_context_compact?(tool_calls) do
    Enum.any?(tool_calls, fn
      %ToolCall{name: "context", arguments: %{"action" => "compact"}} -> true
      _ -> false
    end)
  end

  defp handle_solo_context_compact(ctx, %ToolCall{} = tool_call) do
    case request_compaction_from_task(ctx, tool_call) do
      :stopped ->
        raise __MODULE__.StoppedError

      text ->
        %ToolResult{
          tool_call_id: tool_call.id,
          name: "context",
          arguments: tool_call.arguments,
          content: ensure_non_empty_tool_result(text),
          is_error: false
        }
    end
  end

  defp refuse_context_compact_co_batch(tool_calls) do
    reason =
      "Batch refused: context.compact must be the sole tool in a batch " <>
        "(current batch contains other tools as well). Call context.compact " <>
        "in its own iteration."

    Enum.map(tool_calls, fn tc ->
      %ToolResult{
        tool_call_id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        content: reason,
        is_error: true
      }
    end)
  end

  # Raised by the tool executor when the agent interrupts the chat
  # task mid-tool-call. The tool worker unwinds without making any
  # further LLM calls; the agent's stop handler finalizes whatever
  # is in `state.chat_state.streaming_acc` on the GenServer side.
  defmodule StoppedError do
    @moduledoc "Raised when the agent sends `{:stop_chat, _}` during compaction."
    defexception message: "chat task stopped by user"
  end

  # Round-trip the compaction request through the GenServer. The
  # chat task sends a request, then blocks on a receive for the
  # result. The GenServer runs the compactor (in a Task) and
  # sends the new messages back. The chat task then constructs
  # a synthetic tool result for the LLM.
  #
  # The `{:stop_chat, from}` clause lets the agent interrupt the
  # chat task while it is waiting on a compaction call. The chat
  # task acknowledges the stop and returns `:stopped`, which the
  # caller (the tool worker) treats as "unwind the chain".
  defp request_compaction_from_task(ctx, tool_call) do
    focus = get_focus_arg(tool_call)

    send(ctx.agent_pid, {:task_compaction_request, self(), focus})

    receive do
      {:task_compaction_done, new_messages} ->
        "Compacted #{state_messages_count(ctx)} messages into a summary. You now have ~#{estimate_new_working_space(new_messages, ctx.context_limit)} tokens of working space."

      {:task_compaction_failed, reason} ->
        "Compaction failed: #{inspect(reason)}"

      {:stop_chat, from} ->
        send(from, :stopped)
        :stopped
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

  # Helper for the synthetic tool result string.
  defp state_messages_count(ctx) do
    length(ctx.messages || [])
  end

  defp estimate_new_working_space(new_messages, context_limit) do
    case context_limit do
      nil ->
        "unknown"

      limit when is_integer(limit) ->
        used = Estimator.estimate_messages(new_messages)
        max(0, limit - used - @budget_reserve)
    end
  end

  defp ensure_non_empty_tool_result(""), do: "[no output]"
  defp ensure_non_empty_tool_result(s) when is_binary(s), do: s
end
