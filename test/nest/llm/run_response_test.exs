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

      call = %ToolCall{id: "c1", name: "shell_cmd", arguments: %{}}
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: [call]}) == true

      other = %ToolCall{id: "c2", name: "read_file", arguments: %{}}
      assert RunResponse.has_tool_calls?(%RunResponse{tool_calls: [call, other]}) == true
    end
  end
end
