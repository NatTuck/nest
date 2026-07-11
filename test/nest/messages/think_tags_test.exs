defmodule Nest.Messages.ThinkTagsTest do
  @moduledoc """
  Tests for `Nest.Messages.ThinkTags`.

  Covers:
  - No markers → returns input unchanged.
  - Single block → removed.
  - Multiple blocks → all removed.
  - Nested `<think>` inside a think block → outer block
    consumes the matching close; inner is text inside.
  - Empty think block (`<think></think>`) → removed.
  - Orphan `</think>` (no matching `<think>`) → orphan and
    everything after is removed.
  - Orphan `<think>` (no matching `</think>`) → from orphan
    to end is removed.
  - Non-binary input → returns "".
  - `strip_from_parts/1` rewrites `Part.Text`, passes other
    kinds through unchanged.
  - Stray `</think>\n\n` (the OpenAI-style regression) → the
    stray text and tail are removed.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.Part
  alias Nest.Messages.ThinkTags

  describe "strip/1 — no markers" do
    test "returns the input unchanged" do
      assert ThinkTags.strip("hello world") == "hello world"
    end

    test "returns empty string unchanged" do
      assert ThinkTags.strip("") == ""
    end

    test "returns non-binary input as empty string" do
      assert ThinkTags.strip(nil) == ""
      assert ThinkTags.strip(42) == ""
      assert ThinkTags.strip(:atom) == ""
      assert ThinkTags.strip(%{}) == ""
    end
  end

  describe "strip/1 — single block" do
    test "removes a single <think>...</think> block" do
      assert ThinkTags.strip("before<think>reasoning</think>after") ==
               "beforeafter"
    end

    test "removes a block that takes the whole string" do
      assert ThinkTags.strip("<think>reasoning</think>") == ""
    end

    test "removes a block with surrounding newlines" do
      assert ThinkTags.strip("line1\n<think>\nreasoning\n</think>\nline2\n") ==
               "line1\n\nline2\n"
    end
  end

  describe "strip/1 — multiple blocks" do
    test "removes all blocks" do
      assert ThinkTags.strip("a<think>1</think>b<think>2</think>c") == "abc"
    end

    test "preserves text between blocks" do
      assert ThinkTags.strip("<think>a</think> middle <think>b</think>") == " middle "
    end
  end

  describe "strip/1 — nested and edge cases" do
    test "treats nested <think> inside a think block as text" do
      # The inner `<think>...end` is text inside the outer
      # think block. The outer block closes at the FINAL
      # `</think>`. The inner `</think>` (after `inner`) is
      # consumed to keep the outer block from closing early.
      assert ThinkTags.strip("a<think>outer<think>inner</think>end</think>b") ==
               "ab"
    end

    test "removes an empty think block" do
      assert ThinkTags.strip("before<think></think>after") == "beforeafter"
    end

    test "removes an orphan </think> (no matching <think>)" do
      # Stray closing tag and everything after is reasoning.
      assert ThinkTags.strip("before</think>after") == "before"
    end

    test "removes an orphan <think> (no matching </think>)" do
      # Incomplete think block; the rest is reasoning.
      assert ThinkTags.strip("before<think>reasoning") == "before"
    end

    test "treats </think>\\n\\n as an orphan closing (OpenAI-style regression)" do
      # The exact stray-text pattern from the regression:
      # `</think>\n\n` leaking into the assistant's reply.
      assert ThinkTags.strip("hello</think>\n\nworld") == "hello"
    end
  end

  describe "strip_from_parts/1" do
    test "rewrites Part.Text" do
      parts = [
        %Part.Text{text: "before<think>reasoning</think>after"},
        %Part.Text{text: "no markers"}
      ]

      assert ThinkTags.strip_from_parts(parts) == [
               %Part.Text{text: "beforeafter"},
               %Part.Text{text: "no markers"}
             ]
    end

    test "passes other part kinds through unchanged" do
      tool_use = %Part.ToolUse{id: "1", name: "x", arguments: %{}}
      tool_result = %Part.ToolResult{tool_call_id: "1", name: "x", content: "ok"}
      thinking = %Part.Thinking{thinking: "inner reasoning"}
      refusal = %Part.Refusal{refusal: "no"}

      parts = [
        tool_use,
        %Part.Text{text: "<think>r</think>after"},
        tool_result,
        thinking,
        refusal
      ]

      assert ThinkTags.strip_from_parts(parts) == [
               tool_use,
               %Part.Text{text: "after"},
               tool_result,
               thinking,
               refusal
             ]
    end

    test "returns empty list for non-list input" do
      assert ThinkTags.strip_from_parts(nil) == []
      assert ThinkTags.strip_from_parts(42) == []
      assert ThinkTags.strip_from_parts(:atom) == []
    end

    test "returns empty list for empty list" do
      assert ThinkTags.strip_from_parts([]) == []
    end
  end
end
