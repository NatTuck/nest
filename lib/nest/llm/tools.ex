defmodule Nest.LLM.Tools do
  @moduledoc """
  Nest-native tool executor.

  Walks the tool calls returned by the LLM, looks each up in the
  registered `Nest.LLM.Tool` list, invokes the tool's function
  with the decoded arguments and the per-call context, and
  returns the result as a `Nest.Messages.ToolResult` ready for
  the agent to persist.
  """

  alias Nest.LLM.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  @empty_output_placeholder "[Command executed successfully with no output]"

  @doc """
  Execute a list of tool calls against the registered tools.

  Each call is matched to a tool by `name` (case-insensitive
  lookup, exact match preferred). Unknown tool names yield
  `{:error, "Unknown tool: <name>"}` results so the LLM gets
  feedback instead of a silent skip.

  The `context` map is forwarded to every tool's function. The
  agent passes `%{caps: ...}` here, and tools that respect the
  sandbox read `context.caps`.
  """
  @spec execute([Tool.t()], [ToolCall.t()], map()) :: [ToolResult.t()]
  def execute(tool_defs, calls, context) when is_list(calls) do
    tool_map = index_by_name(tool_defs)

    Enum.map(calls, fn %ToolCall{id: id, name: name, arguments: args} ->
      case Map.get(tool_map, name) do
        nil ->
          %ToolResult{
            tool_call_id: id,
            name: name,
            content: "Unknown tool: #{name}",
            arguments: args || %{},
            is_error: true
          }

        %Tool{function: fun} ->
          result = invoke(fun, args || %{}, context)
          to_result(id, name, args || %{}, result)
      end
    end)
  end

  @doc """
  Execute a single tool call and return the raw result.

  Returns the underlying `{:ok, content}` / `{:error, reason}`
  tuple from the tool's function without wrapping it in a
  `ToolResult` struct. Used by the agent's per-call budget loop
  (`Nest.Tokens.BudgetPlanner`) which wraps, truncates, or skips
  the result before persisting it.
  """
  @spec execute_one([Tool.t()], ToolCall.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute_one(tool_defs, %ToolCall{name: name, arguments: args}, context) do
    case Enum.find(tool_defs, fn %Tool{name: n} -> n == name end) do
      nil -> {:error, "Unknown tool: #{name}"}
      %Tool{function: fun} -> invoke(fun, args || %{}, context)
    end
  end

  defp invoke(fun, args, context) when is_function(fun, 2) do
    fun.(args, context)
  end

  @doc """
  Look up a tool's `max_result_tokens` default by name. Returns
  `nil` if the tool isn't found.
  """
  @spec default_max_result_tokens([Tool.t()], String.t()) :: pos_integer() | nil
  def default_max_result_tokens(tool_defs, name) do
    case Enum.find(tool_defs, fn %Tool{name: n} -> n == name end) do
      nil -> nil
      %Tool{max_result_tokens: max} -> max
    end
  end

  defp to_result(id, name, args, {:ok, content}) do
    %ToolResult{
      tool_call_id: id,
      name: name,
      content: ensure_non_empty(content),
      arguments: args,
      is_error: false
    }
  end

  defp to_result(id, name, args, {:error, reason}) do
    %ToolResult{
      tool_call_id: id,
      name: name,
      content: ensure_non_empty(reason),
      arguments: args,
      is_error: true
    }
  end

  defp to_result(id, name, args, other) do
    %ToolResult{
      tool_call_id: id,
      name: name,
      content: ensure_non_empty(to_string(other)),
      arguments: args,
      is_error: true
    }
  end

  defp ensure_non_empty(""), do: @empty_output_placeholder
  defp ensure_non_empty(nil), do: @empty_output_placeholder
  defp ensure_non_empty(s) when is_binary(s), do: s

  defp index_by_name(tool_defs) do
    Map.new(tool_defs, fn %Tool{name: name} = tool -> {name, tool} end)
  end
end
