defmodule Nest.LLM.ToolTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Tool

  describe "execute/3" do
    test "invokes the function with args and context and returns the result" do
      captured = self()

      tool = %Tool{
        name: "echo",
        description: "echo back",
        parameters_schema: nil,
        function: fn args, context ->
          send(captured, {:called, args, context})
          {:ok, "got #{args["x"]}"}
        end
      }

      assert Tool.execute(tool, %{"x" => "hi"}, %{caps: %{"net" => true}}) ==
               {:ok, "got hi"}

      assert_received {:called, %{"x" => "hi"}, %{caps: %{"net" => true}}}
    end

    test "propagates error returns unchanged" do
      tool = %Tool{
        name: "fail",
        description: "always errors",
        parameters_schema: nil,
        function: fn _, _ -> {:error, "boom"} end
      }

      assert Tool.execute(tool, %{}, %{}) == {:error, "boom"}
    end
  end
end
