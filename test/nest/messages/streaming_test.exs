defmodule Nest.Messages.StreamingTest do
  @moduledoc """
  Coverage pin for `Nest.messages.Streaming`. The streaming
  accumulator is exercised by many tests across the suite
  (chat turn tests, mock-client tests, etc.), but the coverage
  is sensitive to test ordering because different tests hit
  different code paths. This module pins the coverage at a
  deterministic value regardless of which other tests run
  before it, so `mix precommit` (which uses `mix test
  --cover` with strict coverage thresholds) doesn't flake on
  the streaming.ex lines that are only hit by some test paths.

  Each test below exercises a public function of the
  accumulator that the rest of the suite touches only
  incidentally.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.Streaming
  alias Nest.Messages.Streaming.AssistantAccumulator

  test "new/1 creates an empty accumulator" do
    acc = Streaming.new(0)
    assert acc.index == 0
    assert acc.text_buffer == []
    assert acc.thinking_buffer == []
    assert acc.tool_calls == %{}
    assert acc.segments == []
    assert acc.chars_sent == 0
    assert acc.refusal == nil
    assert acc.thinking_signature == nil
  end

  test "append_text/2 accumulates text into the buffer" do
    acc = Streaming.new(0)
    acc = Streaming.append_text(acc, "Hello, ")
    acc = Streaming.append_text(acc, "world!")

    # The buffer is an IO list; multiple appends may pre-reverse
    # for performance. The semantic content is preserved.
    joined = IO.iodata_to_binary(acc.text_buffer)
    assert joined =~ "Hello,"
    assert joined =~ "world!"
  end

  test "append_text/2 raises FunctionClauseError on non-binary input" do
    # The function is guarded with `is_binary/1`; non-binary input
    # is the caller's bug, not the function's to silently handle.
    acc = Streaming.new(0)

    assert_raise FunctionClauseError, fn ->
      Streaming.append_text(acc, nil)
    end
  end

  test "append_thinking/3 accumulates thinking content" do
    acc = Streaming.new(0)
    acc = Streaming.append_thinking(acc, "reasoning step 1")
    acc = Streaming.append_thinking(acc, "more reasoning")

    joined = IO.iodata_to_binary(acc.thinking_buffer)
    assert joined =~ "reasoning step 1"
    assert joined =~ "more reasoning"
  end

  test "append_thinking/3 with a signature sets the thinking_signature" do
    acc = Streaming.new(0)
    acc = Streaming.append_thinking(acc, "thought", "sig-123")
    assert acc.thinking_signature == "sig-123"
  end

  test "start_tool_call/3 starts a partial tool call" do
    acc = Streaming.new(0)
    acc = Streaming.start_tool_call(acc, "call_1", "read_file")
    assert Map.has_key?(acc.tool_calls, "call_1")
    tc = acc.tool_calls["call_1"]
    assert tc.id == "call_1"
    assert tc.name == "read_file"
    assert tc.complete? == false
  end

  test "append_tool_call_args/3 accumulates arguments into the buffer" do
    acc = Streaming.new(0)
    acc = Streaming.start_tool_call(acc, "call_1", "read_file")
    acc = Streaming.append_tool_call_args(acc, "call_1", ~s({"path":))
    acc = Streaming.append_tool_call_args(acc, "call_1", ~s("foo.txt"}))
    tc = acc.tool_calls["call_1"]

    # The buffer is an IO list; we don't pin the exact ordering
    # since the implementation may prepend for performance.
    joined = IO.iodata_to_binary(tc.arguments_buffer)
    assert joined =~ ~s("path")
    assert joined =~ ~s("foo.txt")
  end

  test "complete_tool_call/2 marks a partial tool call complete" do
    acc = Streaming.new(0)
    acc = Streaming.start_tool_call(acc, "call_1", "read_file")
    acc = Streaming.append_tool_call_args(acc, "call_1", ~s({}))
    acc = Streaming.complete_tool_call(acc, "call_1")
    assert acc.tool_calls["call_1"].complete? == true
  end

  test "finalize/1 returns a complete Assistant struct" do
    acc = Streaming.new(0)
    acc = Streaming.append_text(acc, "answer")
    finalized = Streaming.finalize(acc)

    assert %Nest.Messages.Assistant{index: 0, parts: parts} = finalized
    assert [%Nest.Messages.Part.Text{text: "answer"}] = parts
  end

  test "to_json/1 serializes a text-only accumulator" do
    acc = Streaming.new(3)
    acc = Streaming.append_text(acc, "hello")
    json = Streaming.to_json(acc)

    assert json["index"] == 3
    assert json["role"] == "assistant"
    assert json["content"] == "hello"
    assert is_list(json["segments"])
  end
end
