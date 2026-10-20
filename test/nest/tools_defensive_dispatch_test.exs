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
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  # The *real* tool schemas are the ones the model sees, and their
  # closures pattern-match strictly (`fn %{"path" => path}, context ->`),
  # so the schema's `"required"` list is the only thing that turns an
  # argument-less call into a structured error instead of a rescued
  # crash. `Nest.LLM.ToolsTest` covers the validation logic itself with
  # synthetic schemas; this covers the schemas shipped to the model.
  test "real file tools return a structured error naming the missing required args" do
    for {name, caps, missing} <- [
          {"file-write", %{"fs" => %{"write" => ["/tmp"]}}, ["path", "content"]},
          {"file-read", %{"fs" => %{"read" => ["/"]}}, ["path"]}
        ] do
      tool = Tools.get_function(name, Mounts.new("/tmp", nil))

      assert {:error, msg} =
               LLMTools.execute_one(
                 [tool],
                 %ToolCall{id: "c1", name: name, arguments: %{}},
                 %{caps: caps}
               )

      assert msg =~ "Missing required arguments"

      for field <- missing do
        assert msg =~ field, "#{name} error did not name #{field}: #{msg}"
      end
    end
  end
end
