defmodule Nest.LLM.SSE.ParserTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.SSE.Parser

  describe "feed/2 — single complete frame in one chunk" do
    test "parses a single Anthropic-style named event" do
      parser = Parser.new()
      input = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [
               {:event, "message_start", "{\"type\":\"message_start\"}"}
             ]
    end
  end

  describe "feed/2 — multiple frames and multi-line data" do
    test "yields multiple frames in order, joined with multiple data: lines per spec" do
      parser = Parser.new()
      input = "data: a\ndata: b\n\ndata: c\n\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [
               {:event, nil, "a\nb"},
               {:event, nil, "c"}
             ]
    end
  end

  describe "feed/2 — chunk boundary handling" do
    test "buffers a partial line until the rest arrives" do
      parser = Parser.new()

      assert {[], parser} = Parser.feed(parser, "data: hel")
      {frames, parser} = Parser.feed(parser, "lo world\n\n")

      assert frames == [{:event, nil, "hello world"}]

      {more_frames, _parser} = Parser.feed(parser, "data: again\n\n")
      assert more_frames == [{:event, nil, "again"}]
    end

    test "handles CR/LF line endings" do
      parser = Parser.new()
      input = "data: hello\r\n\r\ndata: world\r\n\r\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [
               {:event, nil, "hello"},
               {:event, nil, "world"}
             ]
    end

    test "buffers a data line whose terminating blank line spans chunks" do
      parser = Parser.new()

      assert {[], parser} = Parser.feed(parser, "data: hello\n")
      {frames, _parser} = Parser.feed(parser, "\n")
      assert frames == [{:event, nil, "hello"}]
    end
  end

  describe "feed/2 — comments and unknown fields" do
    test "ignores comment lines" do
      parser = Parser.new()
      input = ": this is a comment\ndata: hello\n\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [{:event, nil, "hello"}]
    end

    test "ignores unknown field lines" do
      parser = Parser.new()
      input = "id: 42\nretry: 1000\ndata: hello\n\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [{:event, nil, "hello"}]
    end

    test "treats empty event name as nil" do
      parser = Parser.new()
      input = "event: \ndata: hello\n\n"
      {frames, _parser} = Parser.feed(parser, input)

      assert frames == [{:event, nil, "hello"}]
    end
  end

  describe "flush/1" do
    test "emits a pending frame whose data line has no trailing newline" do
      parser = Parser.new()
      assert {[], parser} = Parser.feed(parser, "data: hello")
      {frames, _parser} = Parser.flush(parser)

      assert frames == [{:event, nil, "hello"}]
    end

    test "returns no frame when nothing is pending" do
      parser = Parser.new()
      {frames, _parser} = Parser.flush(parser)

      assert frames == []
    end

    test "clears the buffer so subsequent feeds start fresh" do
      parser = Parser.new()
      {_, parser} = Parser.feed(parser, "data: first")
      {_, parser} = Parser.flush(parser)
      {frames, _parser} = Parser.feed(parser, "data: second\n\n")

      assert frames == [{:event, nil, "second"}]
    end
  end
end
