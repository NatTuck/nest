defmodule Nest.Agents.Agent.ToolLoop do
  @moduledoc """
  Per-tool execution for the LLM tool-call loop, with
  BatchSizer-driven deterministic sizing.

  Called by `Nest.Agents.Agent.ChatTurn` after a response
  with `tool_calls` is received. Responsibilities:

    * Delegate non-empty batches to `Nest.Agents.Agent.BatchSizer`,
      which handles preflight + execute + keep-or-summarize.

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
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

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
      calls -> BatchSizer.run(calls, ctx)
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
end
