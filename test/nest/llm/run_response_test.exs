defmodule Nest.LLM.RunResponseTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.Messages.ToolCall

  describe "has_tool_calls?/1" do
    test "is false for a response with no tool calls and true otherwise" do
      assert RunResponse.has_tool_calls?(%RunResponse{}) == false

      call = %ToolCall{id: "c1", name: "shell-cmd", arguments: %{}}
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: [call]}) == true
    end
  end

  describe "truncated?/1" do
    test "is true for Anthropic's max_tokens and OpenAI's length, false otherwise" do
      assert RunResponse.truncated?(%RunResponse{stop_reason: "max_tokens"}) == true
      assert RunResponse.truncated?(%RunResponse{stop_reason: "length"}) == true
      assert RunResponse.truncated?(%RunResponse{}) == false
      assert RunResponse.truncated?(%RunResponse{stop_reason: "tool_calls"}) == false
    end
  end
end
