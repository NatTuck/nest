defmodule Nest.LLM.Tools do
  @moduledoc """
  Nest-native tool executor.

  Walks the tool calls returned by the LLM, looks each up in the
  registered `Nest.LLM.Tool` list, invokes the tool's function
  with the decoded arguments and the per-call context, and
  returns the result as a `Nest.Messages.ToolResult` ready for
  the agent to persist.

  Defensive dispatch: validates each call's arguments against the
  tool's `parameters_schema["required"]` before invoking, and
  wraps the function call in a `try/rescue` so a tool crash
  (e.g. a `FunctionClauseError` from a strict pattern match)
  becomes a structured `{:error, ...}` tool result instead of
  killing the chat task. The LLM then gets the error as a tool
  result and can retry.
  """

  require Logger

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
  def execute(tool_defs, calls, context) when is_list(calls) and is_list(tool_defs) do
    tool_map = index_by_name(tool_defs)
    Enum.map(calls, &dispatch_call(&1, tool_map, context))
  end

  def execute(tool_defs, calls, _context) when is_list(calls) do
    Logger.error("Tool list unavailable during execute (got: #{inspect(tool_defs)})")

    Enum.map(calls, fn %ToolCall{id: id, name: name} ->
      %ToolResult{
        tool_call_id: id,
        name: name,
        content: "Tool list unavailable; cannot execute `#{name}`",
        arguments: nil,
        is_error: true
      }
    end)
  end

  defp dispatch_call(%ToolCall{id: id, name: name, arguments: args}, tool_map, context) do
    args = args || %{}

    case Map.get(tool_map, name) do
      nil ->
        %ToolResult{
          tool_call_id: id,
          name: name,
          content: "Unknown tool: #{name}",
          arguments: args,
          is_error: true
        }

      %Tool{} = tool ->
        case validate_args(tool, args) do
          :ok ->
            to_result(id, name, args, invoke(tool, tool.function, args, context))

          {:error, _reason} = err ->
            to_result(id, name, args, err)
        end
    end
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
  def execute_one(tool_defs, %ToolCall{name: name, arguments: args}, context)
      when is_list(tool_defs) do
    case Enum.find(tool_defs, fn %Tool{name: n} -> n == name end) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      %Tool{} = tool ->
        case validate_args(tool, args) do
          :ok -> invoke(tool, tool.function, args || %{}, context)
          {:error, _reason} = err -> err
        end
    end
  end

  def execute_one(tool_defs, %ToolCall{name: name}, _context) do
    Logger.error("Tool list unavailable when executing `#{name}` (got: #{inspect(tool_defs)})")

    {:error, "Tool list unavailable; cannot execute `#{name}`"}
  end

  # Validate that every field listed in the tool's schema's
  # `"required"` array is present in `args`. Returns
  # `{:error, ...}` with a concise message naming the missing
  # fields so the LLM can retry with the right args. Returns
  # `:ok` for tools without a `"required"` field, so ad-hoc test
  # tools keep working unchanged.
  #
  # Defensive dispatch layer: the LLM may emit a `tool_use`
  # block with no `input_json_delta` events (observed with
  # qwen3.5-plus via model-studio's Anthropic protocol), which
  # decodes to an empty `%{}` arguments map. Without this
  # check, the tool's anonymous fn would raise
  # `FunctionClauseError` and crash the chat task. With it,
  # the LLM gets a clear "missing required arguments" error
  # as a tool result and can retry.
  defp validate_args(%Tool{} = tool, args) when is_map(args) do
    required_fields = get_in(args_schema(tool), ["required"]) || []

    missing = Enum.reject(required_fields, fn k -> is_map_key(args, k) end)

    if missing == [] do
      :ok
    else
      {:error, missing_required_msg(missing)}
    end
  end

  # `validate_args/2` is called from `dispatch_call/3` with
  # `args = args || %{}` already normalized, and from
  # `execute_one/3` with `args = args || %{}` already
  # normalized. We don't expect `nil` here, but pattern-match
  # defensively so a future caller doesn't crash.
  defp validate_args(%Tool{}, nil), do: :ok

  # Helper: read the `"required"` list from the tool's
  # `parameters_schema`. Uses the function's own `Tool` struct
  # (which carries the schema), so this works for any tool
  # registered with `Nest.LLM.Tools`.
  defp args_schema(%Tool{parameters_schema: nil}), do: %{}
  defp args_schema(%Tool{parameters_schema: schema}), do: schema

  # Helper: build the user-facing error string. Kept separate
  # so the wording is easy to tweak without touching the
  # dispatch logic.
  defp missing_required_msg([]), do: "Missing required arguments"

  defp missing_required_msg(missing) do
    "Missing required arguments: #{Enum.join(missing, ", ")}"
  end

  # `invoke/4` wraps the tool's function in a try/rescue so
  # any unexpected crash (e.g. a `FunctionClauseError` from a
  # tool that pattern-matches on a value type, or a runtime
  # error from the sandbox) becomes a structured `{:error, ...}`
  # tuple instead of killing the chat task. The original error
  # is logged at `:error` level on the server for debugging.
  defp invoke(%Tool{name: name}, fun, args, context) when is_function(fun, 2) do
    fun.(args, context)
  rescue
    e ->
      Logger.error("[#{name}] tool crashed: #{Exception.message(e)} (args: #{inspect(args)})")

      {:error, "Tool `#{name}` crashed: #{Exception.message(e)}"}
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
