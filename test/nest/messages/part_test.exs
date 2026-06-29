defmodule Nest.Messages.PartTest do
  use ExUnit.Case, async: true

  alias Nest.Messages.Part
  alias Nest.Messages.Part.{Refusal, Text, Thinking, ToolResult, ToolUse}

  describe "kind/1" do
    test "returns :text for %Text{}" do
      assert Part.kind(%Text{text: "hi"}) == :text
    end

    test "returns :thinking for %Thinking{}" do
      assert Part.kind(%Thinking{thinking: "hmm"}) == :thinking
    end

    test "returns :tool_use for %ToolUse{}" do
      assert Part.kind(%ToolUse{id: "x", name: "n", arguments: %{}}) == :tool_use
    end

    test "returns :tool_result for %ToolResult{}" do
      assert Part.kind(%ToolResult{tool_call_id: "x", name: "n", content: "r"}) ==
               :tool_result
    end

    test "returns :refusal for %Refusal{}" do
      assert Part.kind(%Refusal{refusal: "nope"}) == :refusal
    end
  end

  describe "to_json/1 and from_json/1 round-trip" do
    test "Text" do
      part = %Text{text: "hello"}
      assert Part.from_json(Part.to_json(part)) == part
    end

    test "Thinking with signature" do
      part = %Thinking{thinking: "hmm", signature: "sig-abc"}
      assert Part.from_json(Part.to_json(part)) == part
    end

    test "Thinking without signature" do
      part = %Thinking{thinking: "hmm", signature: nil}
      assert Part.from_json(Part.to_json(part)) == part
    end

    test "ToolUse" do
      part = %ToolUse{id: "call_1", name: "read_file", arguments: %{"path" => "foo.ex"}}
      assert Part.from_json(Part.to_json(part)) == part
    end

    test "ToolResult with is_error" do
      part = %ToolResult{
        tool_call_id: "call_1",
        name: "read_file",
        content: "ok",
        arguments: %{"path" => "foo.ex"},
        is_error: true
      }

      assert Part.from_json(Part.to_json(part)) == part
    end

    test "ToolResult with is_error=false coerced to false when nil" do
      part = %ToolResult{tool_call_id: "x", name: "n", content: "r", is_error: nil}
      assert Part.to_json(part)["isError"] == false
    end

    test "Refusal" do
      part = %Refusal{refusal: "no"}
      assert Part.from_json(Part.to_json(part)) == part
    end
  end

  describe "from_json/1" do
    test "returns nil for unknown kind" do
      assert Part.from_json(%{"kind" => "nope"}) == nil
    end

    test "returns nil for malformed tool_use (non-map arguments)" do
      assert Part.from_json(%{
               "kind" => "tool_use",
               "id" => "x",
               "name" => "n",
               "arguments" => []
             }) ==
               nil
    end
  end

  describe "to_json/1 wire keys" do
    test "ToolResult uses camelCase toolCallId and isError" do
      json = Part.to_json(%ToolResult{tool_call_id: "c", name: "n", content: "r"})
      assert Map.has_key?(json, "toolCallId")
      assert Map.has_key?(json, "isError")
      refute Map.has_key?(json, "tool_call_id")
    end
  end
end
