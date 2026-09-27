defmodule Nest.LLM.RunResponseTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.Messages.ToolCall

  describe "struct defaults" do
    test "a fresh response has no text, no thinking, no tool calls, and nil everything else" do
      resp = %RunResponse{}

      assert resp.text == nil
      assert resp.thinking == nil
      assert resp.thinking_signature == nil
      assert resp.tool_calls == []
      assert resp.refusal == nil
      assert resp.usage == nil
      assert resp.stop_reason == nil
      assert resp.model == nil
      assert resp.metadata == nil
    end
  end

  describe "has_tool_calls?/1" do
    test "is true with one or more tool calls and false otherwise" do
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: []}) == false
      assert RunResponse.has_tool_calls?(%RunResponse{}) == false

      call = %ToolCall{id: "c1", name: "shell-cmd", arguments: %{}}
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: [call]}) == true

      other = %ToolCall{id: "c2", name: "file-read", arguments: %{}}
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: [call, other]}) == true
    end
  end

  describe "truncated?/1" do
    test "is true for Anthropic's max_tokens and OpenAI's length" do
      assert RunResponse.truncated?(%RunResponse{stop_reason: "max_tokens"}) == true
      assert RunResponse.truncated?(%RunResponse{stop_reason: "length"}) == true
    end

    test "is false for normal and nil stop reasons" do
      assert RunResponse.truncated?(%RunResponse{stop_reason: "stop"}) == false
      assert RunResponse.truncated?(%RunResponse{stop_reason: "tool_calls"}) == false
      assert RunResponse.truncated?(%RunResponse{stop_reason: nil}) == false
      assert RunResponse.truncated?(%RunResponse{}) == false
    end
  end
end
