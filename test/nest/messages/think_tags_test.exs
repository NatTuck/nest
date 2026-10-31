defmodule Nest.Messages.ThinkTagsTest do
  @moduledoc """
  Tests for `Nest.Messages.ThinkTags`.

  The rule is "leading matched pair only": a `<think>…</think>` block at the
  **head** of the text is reasoning and goes; everything else is prose and is
  returned untouched. The orphan and unclosed cases are the regression — the
  old splitter deleted the rest of the string, which silently removed an
  agent's prose from the text the summariser reads whenever the model merely
  *discussed* the tag.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.ThinkTags

  describe "strip/1 — the leading block" do
    test "removes a leading matched block and keeps the prose after it" do
      assert ThinkTags.strip("<think>reasoning</think>The answer is 42.") ==
               "The answer is 42."
    end

    test "removes a block that is the whole string" do
      # This is what `Nest.Tokens.Compactor.validate_summary/1` sees when the
      # model was cut off mid-thinking: strip leaves "", and the empty check
      # reports `:llm_returned_empty`.
      assert ThinkTags.strip("<think>reasoning</think>") == ""
      assert String.trim(ThinkTags.strip("<think>only reasoning</think>")) == ""
    end

    test "removes an empty leading block" do
      assert ThinkTags.strip("<think></think>after") == "after"
    end

    test "ends the block at the first closer" do
      # Nesting is not supported: a nested opener is content and the first
      # `</think>` closes the block.
      assert ThinkTags.strip("<think>outer<think>inner</think>rest</think>tail") ==
               "rest</think>tail"
    end

    test "preserves whitespace and newlines after the block" do
      assert ThinkTags.strip("<think>\nwhy\n</think>\n\nAnswer\n") ==
               "\n\nAnswer\n"
    end
  end

  describe "strip/1 — text that is not a leading block" do
    test "leaves a block in the middle of prose alone" do
      # The exact regression: an assistant message that discusses the tag. The
      # old splitter routed everything after the tag into the reasoning channel.
      assert ThinkTags.strip("before<think>reasoning</think>after") ==
               "before<think>reasoning</think>after"
    end

    test "leaves a leading unclosed <think> alone" do
      assert ThinkTags.strip("<think>reasoning") == "<think>reasoning"
    end

    test "leaves a leading orphan </think> alone" do
      assert ThinkTags.strip("</think>after") == "</think>after"
      assert ThinkTags.strip("hello</think>\n\nworld") == "hello</think>\n\nworld"
    end

    test "leaves a second block alone once the first has gone" do
      assert ThinkTags.strip("<think>1</think>a<think>2</think>b") ==
               "a<think>2</think>b"
    end
  end

  describe "strip/1 — other input" do
    test "returns text with no markers unchanged" do
      assert ThinkTags.strip("hello world") == "hello world"
      assert ThinkTags.strip("") == ""
    end

    test "returns non-binary input as an empty string" do
      assert ThinkTags.strip(nil) == ""
      assert ThinkTags.strip(42) == ""
    end
  end
end
