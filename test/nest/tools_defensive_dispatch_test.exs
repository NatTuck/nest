defmodule Nest.ToolsDefensiveDispatchTest do
  @moduledoc """
  Regression tests for the chat-task FunctionClauseError crash
  caused by the LLM (qwen3.5-plus via model-studio's Anthropic
  protocol) emitting a `tool_use` content block with no
  `input_json_delta` events.

  The arguments buffer decodes to an empty `%{}` map, and a
  strict pattern match in the tool's anonymous fn (e.g.
  `fn %{"path" => path, "content" => content}, context -> ...`)
  raises `FunctionClauseError`, killing the chat task. The fix
  is in `Nest.LLM.Tools.execute_one/3` (validates required args
  before invoking, wraps the invoke in `try/rescue`) — these
  tests exercise the validation end-to-end through the chat
  task's dispatch entry point.

  Split out from `test/nest/tools_test.exs` to keep that file
  under the 500-line cap.
  """
  use ExUnit.Case, async: true

  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.ToolCall
  alias Nest.Tools

  test "write_file returns a structured error when called with no arguments" do
    tool = Tools.get_function("write_file", "/tmp")

    assert {:error, msg} =
             LLMTools.execute_one(
               [tool],
               %ToolCall{id: "c1", name: "write_file", arguments: %{}},
               %{caps: %{"fs" => %{"write" => ["/tmp"]}}}
             )

    assert msg =~ "Missing required arguments"
    assert msg =~ "path"
    assert msg =~ "content"
  end

  test "write_file returns a structured error when only some required args are present" do
    tool = Tools.get_function("write_file", "/tmp")

    assert {:error, msg} =
             LLMTools.execute_one(
               [tool],
               %ToolCall{
                 id: "c1",
                 name: "write_file",
                 arguments: %{"path" => "/tmp/foo"}
               },
               %{caps: %{"fs" => %{"write" => ["/tmp"]}}}
             )

    assert msg =~ "Missing required arguments"
    assert msg =~ "content"
  end

  test "read_file returns a structured error when called with no arguments" do
    tool = Tools.get_function("read_file", "/tmp")

    assert {:error, msg} =
             LLMTools.execute_one(
               [tool],
               %ToolCall{id: "c1", name: "read_file", arguments: %{}},
               %{caps: %{"fs" => %{"read" => ["/"]}}}
             )

    assert msg =~ "Missing required arguments"
    assert msg =~ "path"
  end

  test "shell_cmd returns a structured error when called with no arguments" do
    tool = Tools.get_function("shell_cmd", "/tmp")

    assert {:error, msg} =
             LLMTools.execute_one(
               [tool],
               %ToolCall{id: "c1", name: "shell_cmd", arguments: %{}},
               %{caps: %{}}
             )

    assert msg =~ "Missing required arguments"
    assert msg =~ "command"
  end
end
