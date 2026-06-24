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

  describe "execute_one/3 argument validation" do
    defp tool_with_schema(name, required) do
      %Tool{
        name: name,
        description: name,
        parameters_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => required
        },
        function: fn args, _ctx -> {:ok, "got #{inspect(args)}"} end
      }
    end

    test "returns an error when required args are missing entirely (%{})" do
      tool = tool_with_schema("write_file", ["path", "content"])

      assert {:error, msg} =
               Tools.execute_one(
                 [tool],
                 %ToolCall{id: "c1", name: "write_file", arguments: %{}},
                 %{}
               )

      assert msg =~ "Missing required arguments"
      assert msg =~ "path"
      assert msg =~ "content"
    end

    test "returns an error when only some required args are present" do
      tool = tool_with_schema("write_file", ["path", "content"])

      assert {:error, msg} =
               Tools.execute_one(
                 [tool],
                 %ToolCall{id: "c1", name: "write_file", arguments: %{"path" => "/foo"}},
                 %{}
               )

      assert msg =~ "Missing required arguments"
      assert msg =~ "content"
      refute msg =~ "path"
    end

    test "succeeds when all required args are present" do
      tool = tool_with_schema("write_file", ["path", "content"])

      assert {:ok, content} =
               Tools.execute_one(
                 [tool],
                 %ToolCall{
                   id: "c1",
                   name: "write_file",
                   arguments: %{"path" => "/foo", "content" => "x"}
                 },
                 %{}
               )

      assert content =~ "got"
    end

    test "succeeds when the tool has no required field and args is empty" do
      tool = %Tool{
        name: "noop",
        description: "noop",
        parameters_schema: %{"type" => "object", "properties" => %{}},
        function: fn _, _ -> {:ok, "ok"} end
      }

      assert {:ok, "ok"} =
               Tools.execute_one([tool], %ToolCall{id: "c1", name: "noop", arguments: %{}}, %{})
    end

    test "succeeds when the tool has no required field and args is nil" do
      tool = %Tool{
        name: "noop",
        description: "noop",
        parameters_schema: %{"type" => "object", "properties" => %{}},
        function: fn _, _ -> {:ok, "ok"} end
      }

      assert {:ok, "ok"} =
               Tools.execute_one(
                 [tool],
                 %ToolCall{id: "c1", name: "noop", arguments: nil},
                 %{}
               )
    end
  end

  describe "execute/3 argument validation" do
    test "wraps a missing-required-args error in a ToolResult with is_error: true" do
      tool = %Tool{
        name: "write_file",
        description: "write",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => ["path", "content"]
        },
        function: fn _, _ -> {:ok, "should not run"} end
      }

      results =
        Tools.execute([tool], [%ToolCall{id: "c1", name: "write_file", arguments: %{}}], %{})

      assert [result] = results
      assert result.is_error == true
      assert result.content =~ "Missing required arguments"
      assert result.content =~ "path"
      assert result.content =~ "content"
    end
  end

  describe "invoke defense in depth (try/rescue)" do
    import ExUnit.CaptureLog

    test "rescues a tool that raises FunctionClauseError and returns an error tuple" do
      # The tool's function pattern-matches strictly on
      # `%{"x" => "ok"}` (a literal value, not a binding).
      # Passing `%{"x" => "ok"}` succeeds; passing anything
      # else raises FunctionClauseError. This is exactly the
      # shape of the original user-reported crash
      # (`Nest.Tools.write_file_function/2`'s strict pattern
      # match on `%{"path" => path, "content" => content}`).
      tool = %Tool{
        name: "strict",
        description: "strict pattern match",
        parameters_schema: nil,
        function: fn %{"x" => "ok"}, _ctx -> {:ok, "matched"} end
      }

      log =
        capture_log(fn ->
          assert {:error, msg} =
                   Tools.execute_one(
                     [tool],
                     %ToolCall{id: "c1", name: "strict", arguments: %{"x" => "nope"}},
                     %{}
                   )

          assert msg =~ "Tool `strict` crashed"
        end)

      assert log =~ "[strict] tool crashed"
    end

    test "rescues a tool that raises and is wrapped in a ToolResult by execute/3" do
      tool = %Tool{
        name: "boom",
        description: "raises",
        parameters_schema: nil,
        function: fn _args, _ctx -> raise "kaboom" end
      }

      log =
        capture_log(fn ->
          results =
            Tools.execute(
              [tool],
              [%ToolCall{id: "c1", name: "boom", arguments: %{}}],
              %{}
            )

          assert [result] = results
          assert result.is_error == true
          assert result.content =~ "Tool `boom` crashed"
          assert result.content =~ "kaboom"
        end)

      # The original error is also logged at :error level on the
      # server for debugging.
      assert log =~ "[boom] tool crashed"
      assert log =~ "kaboom"
    end
  end
end
