defmodule Nest.Tokens.SkipResponse do
  @moduledoc """
  Builds a synthetic tool result for a tool call that was *not*
  executed, either because there wasn't enough context budget left
  for it or because a previous result in the same batch consumed
  the remaining budget.

  The skip response replaces the missing `ToolResult` in the
  conversation so the LLM sees a structured reply ("I didn't run
  this; here's why") instead of a missing entry. It's the LLM-
  facing analog of `Truncate.note/3` but for skipped calls.

  Format:

      [skipped: tool '<name>' was not executed — only ~N tokens of
      context budget remain. Reformulate the request (e.g. use a more
      specific path, pipe through a filter, or split into smaller
      calls) before retrying.]
  """

  @template """
  [skipped: tool '<%= tool_name %>' was not executed — only ~<%= budget %> tokens of context budget remain. Reformulate the request (e.g. use a more specific path, pipe through a filter, or split into smaller calls) before retrying.]\
  """

  @doc """
  Build a skip response for a tool call.

  ## Parameters

    * `tool_name` — the name of the tool that was skipped
    * `budget_remaining` — estimated tokens of context budget left
      at the time of the skip. Used to give the LLM a sense of how
      tight the budget is.
  """
  @spec render(String.t(), non_neg_integer()) :: String.t()
  def render(tool_name, budget_remaining)
      when is_binary(tool_name) and is_integer(budget_remaining) do
    EEx.eval_string(@template, tool_name: tool_name, budget: budget_remaining)
  end

  def render(tool_name, _budget_remaining) when is_binary(tool_name) do
    "[skipped: tool '#{tool_name}' was not executed due to insufficient context budget. Reformulate the request before retrying.]"
  end

  def render(_tool_name, _budget_remaining), do: ""
end
