defmodule Nest.LLM.ToolsTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Tool
  alias Nest.LLM.Tools
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  defp tool_with(name, fun) do
    %Tool{name: name, description: name, parameters_schema: nil, function: fun}
  end

  describe "execute/3" do
    test "invokes the matching tool with decoded arguments and context" do
      captured = self()

      tool =
        tool_with("echo", fn args, ctx ->
          send(captured, {:called, args, ctx})
          {:ok, "got #{args["x"]}"}
        end)

      results =
        Tools.execute(
          [tool],
          [%ToolCall{id: "c1", name: "echo", arguments: %{"x" => "hi"}}],
          %{caps: %{"net" => true}}
        )

      assert [
               %ToolResult{
                 tool_call_id: "c1",
                 name: "echo",
                 content: "got hi",
                 arguments: %{"x" => "hi"},
                 is_error: false
               }
             ] = results

      assert_received {:called, %{"x" => "hi"}, %{caps: %{"net" => true}}}
    end

    test "returns an error result for an unknown tool name" do
      results =
        Tools.execute(
          [],
          [%ToolCall{id: "c1", name: "nope", arguments: %{}}],
          %{}
        )

      assert [result] = results
      assert result.tool_call_id == "c1"
      assert result.name == "nope"
      assert result.is_error == true
      assert result.content =~ "Unknown tool: nope"
    end

    test "treats empty tool output as the standard placeholder" do
      tool = tool_with("noop", fn _, _ -> {:ok, ""} end)
      results = Tools.execute([tool], [%ToolCall{id: "c1", name: "noop", arguments: %{}}], %{})

      assert [
               %ToolResult{
                 content: "[Command executed successfully with no output]",
                 arguments: %{},
                 is_error: false
               }
             ] = results
    end

    test "propagates {:error, reason} as a result with is_error = true" do
      tool = tool_with("bad", fn _, _ -> {:error, "boom"} end)
      results = Tools.execute([tool], [%ToolCall{id: "c1", name: "bad", arguments: %{}}], %{})
      assert [%ToolResult{content: "boom", arguments: %{}, is_error: true}] = results
    end

    test "executes all calls in order and returns one result per call" do
      tool_a = tool_with("a", fn _, _ -> {:ok, "out_a"} end)
      tool_b = tool_with("b", fn _, _ -> {:ok, "out_b"} end)

      calls = [
        %ToolCall{id: "1", name: "a", arguments: %{}},
        %ToolCall{id: "2", name: "b", arguments: %{}},
        %ToolCall{id: "3", name: "a", arguments: %{}}
      ]

      results = Tools.execute([tool_a, tool_b], calls, %{})

      assert length(results) == 3
      assert Enum.map(results, & &1.content) == ["out_a", "out_b", "out_a"]
      assert Enum.map(results, & &1.tool_call_id) == ["1", "2", "3"]
    end

    test "passes empty arguments when the LLM sends none" do
      captured = self()

      tool =
        tool_with("noop", fn args, _ ->
          send(captured, {:args, args})
          {:ok, "ok"}
        end)

      Tools.execute([tool], [%ToolCall{id: "c1", name: "noop", arguments: nil}], %{})
      assert_received {:args, %{}}
    end
  end
end
