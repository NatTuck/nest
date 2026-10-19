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

  test "append_text/2 raises FunctionClauseError on non-binary input" do
    # The function is guarded with `is_binary/1`; non-binary input
    # is the caller's bug, not the function's to silently handle.
    acc = Streaming.new(0)

    assert_raise FunctionClauseError, fn ->
      Streaming.append_text(acc, nil)
    end
  end

  test "append_thinking/3 with a signature sets the thinking_signature" do
    acc = Streaming.new(0)
    acc = Streaming.append_thinking(acc, "thought", "sig-123")
    assert acc.thinking_signature == "sig-123"
  end

  test "complete_tool_call/2 marks a partial tool call complete" do
    acc = Streaming.new(0)
    acc = Streaming.start_tool_call(acc, "call_1", "file-read")
    acc = Streaming.append_tool_call_args(acc, "call_1", ~s({}))

    # A call is incomplete from the moment it starts until it completes.
    refute acc.tool_calls["call_1"].complete?

    acc = Streaming.complete_tool_call(acc, "call_1")
    assert acc.tool_calls["call_1"].complete?
  end

  test "finalize/1 assembles multi-fragment text in arrival order (not reversed)" do
    # Regression for "text is garbled/reversed when Stop is pressed":
    # the Stop path finalizes via `Streaming.finalize/1`, which must
    # emit fragments in the order they arrived — not word-reversed.
    acc = Streaming.new(0)
    acc = Streaming.append_text(acc, "Hello ")
    acc = Streaming.append_text(acc, "world")
    acc = Streaming.append_text(acc, "!")

    assert [%Nest.Messages.Part.Text{text: "Hello world!"}] = Streaming.finalize(acc).parts
  end

  test "finalize/1 assembles multi-fragment thinking in arrival order (not reversed)" do
    acc = Streaming.new(0)
    acc = Streaming.append_thinking(acc, "step one ")
    acc = Streaming.append_thinking(acc, "step two")

    assert [%Nest.Messages.Part.Thinking{thinking: "step one step two"}] =
             Streaming.finalize(acc).parts
  end

  test "to_json/1 serializes multi-fragment content in arrival order (not reversed)" do
    # The `partial` payload feeds a re-seed (init / chat:sync); it must
    # carry text in arrival order, not word-reversed.
    acc = Streaming.new(0)
    acc = Streaming.append_text(acc, "Hello ")
    acc = Streaming.append_text(acc, "world")

    assert Streaming.to_json(acc)["content"] == "Hello world"
  end

  describe "to_json/1 with in-flight tool calls" do
    # Regression for the "mid-stream join" gap: the `init`
    # partial payload didn't carry in-flight tool calls, so a
    # client connecting after `tool_use_start` had already
    # fired saw an empty `partial.parts` and rendered no tool
    # card until the next `chat:message` finalized.
    test "includes toolCalls list with partial JSON strings" do
      acc = Streaming.new(2)
      acc = Streaming.append_text(acc, "Let me check")
      acc = Streaming.start_tool_call(acc, "call_abc", "shell-cmd")
      acc = Streaming.append_tool_call_args(acc, "call_abc", ~s({"command":))
      acc = Streaming.append_tool_call_args(acc, "call_abc", ~s("ls"}))

      json = Streaming.to_json(acc)

      assert [%{"id" => "call_abc", "name" => "shell-cmd", "arguments" => args}] =
               json["toolCalls"]

      # The `arguments` field is the raw JSON fragment as it
      # has streamed so far — the JS uses this to render the
      # `stream-short` / `stream-long` discriminated union.
      assert args =~ ~s("command")
      assert args =~ ~s("ls")
    end

    test "includes a tool_use segment marker for each in-flight tool call" do
      acc = Streaming.new(2)
      acc = Streaming.append_text(acc, "before ")
      acc = Streaming.start_tool_call(acc, "call_1", "shell-cmd")
      acc = Streaming.append_text(acc, " after")

      json = Streaming.to_json(acc)

      # Segments are in chronological order on the wire. Text
      # segments keep their atom `type` (becomes "text" over
      # JSON); tool-use markers serialize as `%{"type" =>
      # "tool_use", "id" => id}` with no `content` (the JS
      # looks up the partial JSON via `toolCalls`).
      assert [
               %{"type" => :text, "content" => "before "},
               %{"type" => "tool_use", "id" => "call_1"},
               %{"type" => :text, "content" => " after"}
             ] = json["segments"]
    end

    test "toolCalls is an empty list when no tool calls are in flight" do
      acc = Streaming.new(0)
      acc = Streaming.append_text(acc, "just text")
      json = Streaming.to_json(acc)
      assert json["toolCalls"] == []
    end
  end

  describe "defensive fallthroughs for malformed events" do
    # Regression for `LLMStreamHandler` crashing the Agent
    # when a provider forwards a tool-use event with a
    # non-binary id (e.g. `id: :by_index` leaking through
    # the resolver) or with a fragment for an unknown
    # tool-call id (out-of-order delivery, retransmitted
    # delta after eviction). The accumulator should accept
    # the malformed event, log a warning, and return
    # unchanged — the next event for the same call will
    # also skip.
    import ExUnit.CaptureLog

    test "start_tool_call/3 with a non-binary id returns acc unchanged" do
      acc = Streaming.new(0)
      acc = Streaming.append_text(acc, "x")

      log =
        capture_log(fn ->
          result = Streaming.start_tool_call(acc, :by_index, "shell-cmd")
          assert result == acc
        end)

      assert log =~ "start_tool_call"
      assert log =~ ":by_index"
    end

    test "append_tool_call_args/3 for an unknown id returns acc unchanged" do
      acc = Streaming.new(0)
      acc = Streaming.start_tool_call(acc, "call_real", "shell-cmd")

      log =
        capture_log(fn ->
          result = Streaming.append_tool_call_args(acc, "call_orphan", "{}")
          assert result == acc
        end)

      assert log =~ "append_tool_call_args"
      assert log =~ "call_orphan"
    end

    test "append_tool_call_args/3 with a non-binary fragment returns acc unchanged" do
      acc = Streaming.new(0)
      acc = Streaming.start_tool_call(acc, "call_1", "shell-cmd")

      log =
        capture_log(fn ->
          result = Streaming.append_tool_call_args(acc, "call_1", :not_a_string)
          assert result == acc
        end)

      assert log =~ "append_tool_call_args"
    end
  end
end
