defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by `Nest.Agents.Agent.ChatTurn` after a response
  with `tool_calls` is received. Responsibilities:

    * Split the batch by tool — `clone_agent` is routed
      through `run_clone_agent/2` (synchronous parent →
      spawn → wait → synthetic ToolResult); everything else
      is delegated to `Nest.Agents.Agent.BatchSizer`.
    * Merge the two halves back into input order.

  `context.compact` is no longer routed through this module —
  the chat turn's response handler detects it ahead of the
  tool worker and exits with a `{:compact_tool, _, _, _}`
  continuation. The blocked-tool-worker pattern (where the
  tool worker awaited the compactor on receive) is gone.
  `context_compact?/1` and `strip_context_compact/1` are
  retained for compatibility with `BatchSizer.preflight/2`,
  which strips `context.compact` from its preflight input so
  BatchSizer doesn't try to project a per-tool size for it.
  """

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Registry
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  require Logger

  # Generous default — most sub-agent turns finish in
  # seconds; this protects the worker's `receive` from
  # hanging forever if a child's chat task wedges.
  @clone_agent_wait_ms 120_000

  @doc """
  Run a tool-call batch. Returns a list of `ToolResult`
  structs in input order.

  The `state` argument is unused; kept in the signature for
  symmetry with the call site.
  """
  @spec execute(map(), term(), [ToolCall.t()]) :: [ToolResult.t()]
  def execute(ctx, _state, tool_calls) do
    case tool_calls do
      [] -> []
      calls -> run_batch(ctx, calls)
    end
  end

  @doc """
  Returns true if `tool_call` is a `context.compact` invocation.
  Exposed for `BatchSizer.preflight/2` callers that need to
  strip `context.compact` from their preflight input.
  """
  @spec context_compact?(ToolCall.t()) :: boolean()
  def context_compact?(%ToolCall{name: "context", arguments: %{"action" => "compact"}}),
    do: true

  def context_compact?(_), do: false

  @doc """
  Strip `context.compact` calls out of a tool-call list.
  Returns every other call unchanged.
  """
  @spec strip_context_compact([ToolCall.t()]) :: [ToolCall.t()]
  def strip_context_compact(tool_calls) do
    Enum.reject(tool_calls, &context_compact?/1)
  end

  # Private — batch dispatch.

  # Split the tool-call batch by tool family and route
  # each half to its executor. Re-merge into input order
  # so the chat turn's `{:tool, _}` message carries
  # `ToolResult` parts in the same order as the LLM's
  # `tool_use` parts.
  defp run_batch(ctx, calls) do
    {clone_calls, regular_calls} = Enum.split_with(calls, &clone_agent?/1)

    regular_results =
      if regular_calls == [],
        do: %{},
        else: BatchSizer.run(regular_calls, ctx) |> Map.new(fn tr -> {tr.tool_call_id, tr} end)

    clone_results =
      Enum.map(clone_calls, fn tc ->
        {tc.id, run_clone_agent(ctx, tc)}
      end)
      |> Map.new()

    Enum.map(calls, fn %ToolCall{id: id} ->
      Map.fetch!(regular_results |> Map.merge(clone_results), id)
    end)
  end

  defp clone_agent?(%ToolCall{name: "clone_agent"}), do: true
  defp clone_agent?(_), do: false

  # Synchronous clone path. Sends a `{:clone_agent_request,
  # task_pid, instruction}` to the parent GenServer and
  # blocks on its reply, then awaits the eventual
  # `:clone_agent_result` forwarded from the parent when
  # the child finishes its turn. Returns a single
  # `ToolResult` carrying the child's final assistant
  # content (or an error string on timeout).
  defp run_clone_agent(ctx, %ToolCall{} = tc) do
    instruction = extract_instruction(tc)
    parent_via_tuple = Registry.via_tuple(ctx.agent_name)

    case GenServer.call(parent_via_tuple, {:clone_agent_request, self(), instruction}) do
      {:ok, child_name} ->
        receive do
          {:clone_agent_result, ^child_name, response} ->
            build_clone_result(tc, response, false)
        after
          @clone_agent_wait_ms ->
            Logger.warning(
              "clone_agent: child #{child_name} did not complete within #{@clone_agent_wait_ms}ms"
            )

            build_clone_result(tc, "Child agent did not complete in time.", true)
        end

      {:error, reason} ->
        build_clone_result(tc, "Could not spawn child agent: #{inspect(reason)}", true)
    end
  end

  defp extract_instruction(%ToolCall{arguments: %{"instruction" => i}}) when is_binary(i), do: i

  defp extract_instruction(_), do: ""

  defp build_clone_result(%ToolCall{} = tc, content, is_error) do
    %ToolResult{
      tool_call_id: tc.id,
      name: "clone_agent",
      arguments: tc.arguments,
      content: content,
      is_error: is_error
    }
  end
end
