defmodule Nest.LLM.RunRequestTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.RunRequest
  alias Nest.LLM.Tool
  alias Nest.Messages.System
  alias Nest.Messages.User

  describe "struct defaults" do
    test "an empty request has no messages, no tools, no model, and sensible defaults" do
      req = %RunRequest{}

      assert req.messages == []
      assert req.tools == []
      assert req.model == nil
      assert req.tool_choice == :auto
      assert req.temperature == nil
      assert req.max_tokens == nil
      assert req.top_p == nil
      assert req.stream == true
      assert req.metadata == nil
    end
  end

  describe "custom values" do
    test "every field round-trips when set explicitly" do
      sys = {:system, %System{index: 0, content: "be helpful"}}
      user = {:user, %User{index: 1, content: "hi"}}

      tool = %Tool{
        name: "shell_cmd",
        description: "run a command",
        parameters_schema: %{type: "object", properties: %{command: %{type: "string"}}},
        function: fn _args, _ctx -> {:ok, "ok"} end
      }

      req = %RunRequest{
        messages: [sys, user],
        tools: [tool],
        model: "gpt-4o",
        tool_choice: :required,
        temperature: 0.3,
        max_tokens: 1024,
        top_p: 0.9,
        stream: false,
        metadata: %{"reasoning_field" => "reasoning_content"}
      }

      assert req.messages == [sys, user]
      assert length(req.tools) == 1
      assert hd(req.tools).name == "shell_cmd"
      assert req.model == "gpt-4o"
      assert req.tool_choice == :required
      assert req.temperature == 0.3
      assert req.max_tokens == 1024
      assert req.top_p == 0.9
      assert req.stream == false
      assert req.metadata == %{"reasoning_field" => "reasoning_content"}
    end

    test "tool_choice accepts the four canonical forms" do
      for choice <- [:auto, :none, :required, {:tool, "shell_cmd"}] do
        assert %RunRequest{tool_choice: ^choice} = %RunRequest{tool_choice: choice}
      end
    end
  end
end
