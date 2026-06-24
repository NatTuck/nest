defmodule Nest.Agents.Agent.ToolLoopErrorFlagTest do
  @moduledoc """
  Regression tests for the chat-path `is_error` flag.

  The agent's tool loop (`Nest.Agents.Agent.ToolLoop`) wraps each
  `ToolCall`'s executor result into a `ToolResult` that the LLM
  sees. When the executor returns `{:error, reason, _}` (e.g. an
  unknown tool name, a tool with missing required args, or a tool
  that crashed), the resulting `ToolResult.is_error` must be
  `true` so the LLM can see the failure and retry.

  Previously, `wrap_result/1` only set `is_error: true` when the
  content started with `"[skipped:"` (the BudgetPlanner's skip
  marker). All other errors — including the most common ones —
  shipped with `is_error: false`, hiding the failure from the
  LLM. The fix threads a `:ok | :error` kind tag from the
  executor through the BudgetPlanner to `wrap_result/1`.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.LLM.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tools

  defp make_ctx(tools) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => true},
      context_limit: 100_000,
      messages: []
    }
  end

  describe "is_error flag for unknown tool calls" do
    test "unknown tool name yields is_error: true in the chat path" do
      ctx =
        make_ctx([
          %Tool{
            name: "echo",
            description: "x",
            parameters_schema: nil,
            function: fn _, _ -> {:ok, "hi"} end
          }
        ])

      [%ToolResult{} = result] =
        ToolLoop.execute(ctx, %{}, [
          %ToolCall{id: "c1", name: "nope", arguments: %{}}
        ])

      assert result.is_error == true
      assert result.tool_call_id == "c1"
      assert result.name == "nope"
      assert result.content =~ "Unknown tool: nope"
    end
  end

  describe "is_error flag for missing required args" do
    test "write_file with empty arguments yields is_error: true in the chat path" do
      tool = Tools.get_function("write_file", "/tmp")
      ctx = make_ctx([tool])

      [%ToolResult{} = result] =
        ToolLoop.execute(ctx, %{}, [
          %ToolCall{id: "c1", name: "write_file", arguments: %{}}
        ])

      assert result.is_error == true
      assert result.tool_call_id == "c1"
      assert result.name == "write_file"
      assert result.content =~ "Missing required arguments"
    end
  end

  describe "is_error flag is false on the happy path" do
    test "successful tool execution yields is_error: false" do
      tool = %Tool{
        name: "echo",
        description: "echo",
        parameters_schema: nil,
        function: fn args, _ctx -> {:ok, "got #{args["x"]}"} end
      }

      ctx = make_ctx([tool])

      [%ToolResult{} = result] =
        ToolLoop.execute(ctx, %{}, [
          %ToolCall{id: "c1", name: "echo", arguments: %{"x" => "hi"}}
        ])

      assert result.is_error == false
      assert result.content =~ "got hi"
    end

    test "a tool that returns {:error, _} from its function yields is_error: true" do
      tool = %Tool{
        name: "crashy",
        description: "always errors",
        parameters_schema: nil,
        function: fn _, _ -> {:error, "intentional failure"} end
      }

      ctx = make_ctx([tool])

      [%ToolResult{} = result] =
        ToolLoop.execute(ctx, %{}, [
          %ToolCall{id: "c1", name: "crashy", arguments: %{}}
        ])

      assert result.is_error == true
      assert result.content =~ "intentional failure"
    end
  end
end
