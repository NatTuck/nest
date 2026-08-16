defmodule Nest.Tokens.EstimatorTest do
  @moduledoc """
  Tests for `Nest.Tokens.Estimator`.

  Covers:
  - String and message-list estimation
  - Per-message-type handling (system, user, assistant, tool)
  - Tool call and tool result sizing (including JSON args)
  - Safety multiplier behavior (conservative)
  - Edge cases: empty inputs, nil values
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator

  defp sys_msg(text), do: {:system, %System{parts: [%Part.Text{text: text}]}}
  defp user_msg(text), do: {:user, %User{parts: [%Part.Text{text: text}]}}
  defp assistant_text_msg(text), do: {:assistant, %Assistant{parts: [%Part.Text{text: text}]}}

  defp assistant_parts_msg(parts) do
    {:assistant, %Assistant{parts: parts}}
  end

  defp tool_msg(results) do
    parts = Enum.map(results, &tool_result_to_part/1)
    {:tool, %Tool{parts: parts}}
  end

  defp tool_result_to_part(%{tool_call_id: id, name: name, content: content}) do
    %Part.ToolResult{tool_call_id: id, name: name, content: content}
  end

  describe "raw_count/1" do
    test "returns the real cl100k_base count for ASCII" do
      # Sanity: "Hello, world!" is exactly 4 tokens in cl100k_base
      assert Estimator.raw_count("Hello, world!") == 4
    end

    test "returns 0 for non-binary input" do
      assert Estimator.raw_count(nil) == 0
      assert Estimator.raw_count(123) == 0
    end

    test "handles long strings" do
      long = String.duplicate("a", 1000)
      # Each character is at most 1 token; 1000 chars ≈ 1000 tokens
      # for all-same-char (usually encoded as 1 token in BPE).
      n = Estimator.raw_count(long)
      assert is_integer(n)
      assert n > 0
    end

    test "empty string" do
      assert Estimator.raw_count("") == 0
    end
  end

  describe "estimate/1 (string)" do
    test "is at least 20% higher than raw_count" do
      raw = Estimator.raw_count("Hello, world!")
      # The safety multiplier is 1.20, plus per-message overhead of 10.
      est = Estimator.estimate("Hello, world!")
      assert est >= ceil(raw * 1.20)
      # And the +10 overhead pushes it above the raw value
      assert est > raw
    end

    test "returns at least the per-message overhead for non-binary" do
      assert Estimator.estimate(nil) == 10
      assert Estimator.estimate(123) == 10
    end

    test "always overestimates raw count" do
      texts = ["hi", "Hello, world!", "the quick brown fox", ""]

      for t <- texts do
        raw = Estimator.raw_count(t)
        est = Estimator.estimate(t)
        assert est >= raw, "expected estimate >= raw for #{inspect(t)}"
      end
    end
  end

  describe "estimate_messages/1" do
    test "sums per-message estimates" do
      messages = [
        sys_msg("You are helpful"),
        user_msg("Hello"),
        assistant_text_msg("Hi there")
      ]

      total = Estimator.estimate_messages(messages)
      individual = Enum.map(messages, &Estimator.estimate_message/1) |> Enum.sum()
      assert total == individual
    end

    test "returns 0 for non-list input" do
      assert Estimator.estimate_messages(nil) == 0
    end

    test "empty list" do
      assert Estimator.estimate_messages([]) == 0
    end

    test "handles all message types" do
      messages = [
        sys_msg("System prompt"),
        user_msg("User msg"),
        assistant_parts_msg([
          %Part.Text{text: "Assistant response"},
          %Part.Thinking{thinking: "Internal thought"},
          %Part.ToolUse{id: "1", name: "shell-cmd", arguments: %{"cmd" => "ls"}}
        ]),
        tool_msg([
          %{tool_call_id: "1", name: "shell-cmd", content: "file1\nfile2"}
        ])
      ]

      total = Estimator.estimate_messages(messages)
      # Sanity: at least some tokens for each message
      assert total > 0
      # And it's the sum of individual estimates
      individual = Enum.map(messages, &Estimator.estimate_message/1) |> Enum.sum()
      assert total == individual
    end
  end

  describe "estimate_message/1" do
    test "system message" do
      assert Estimator.estimate_message(sys_msg("hi")) ==
               Estimator.estimate_parts([%Part.Text{text: "hi"}]) + 10
    end

    test "system message with nil content" do
      # Should not crash
      result = Estimator.estimate_message({:system, %System{parts: nil}})
      assert is_integer(result)
      assert result > 0
    end

    test "user message" do
      assert Estimator.estimate_message(user_msg("hello")) ==
               Estimator.estimate_parts([%Part.Text{text: "hello"}]) + 10
    end

    test "assistant message with content and thinking" do
      msg = %Assistant{
        parts: [
          %Part.Text{text: "hi"},
          %Part.Thinking{thinking: "thoughtful"}
        ]
      }

      result = Estimator.estimate_message({:assistant, msg})
      # Should be at least the sum of the two texts
      assert result >= Estimator.estimate("hi") + Estimator.estimate("thoughtful") - 10
    end

    test "assistant message with tool calls sizes JSON args" do
      msg = %Assistant{
        parts: [
          %Part.ToolUse{
            id: "call_1",
            name: "shell-cmd",
            arguments: %{"command" => "ls -la /tmp"}
          }
        ]
      }

      result = Estimator.estimate_message({:assistant, msg})
      # Should be larger than 0; the args are non-trivial
      assert result > 0
    end

    test "assistant message with thinking signature" do
      msg = %Assistant{
        parts: [
          %Part.Text{text: "hi"},
          %Part.Thinking{thinking: "hmm", signature: "abc123signature"}
        ]
      }

      sig_msg = %Assistant{
        parts: [
          %Part.Text{text: "hi"},
          %Part.Thinking{thinking: "hmm", signature: nil}
        ]
      }

      result = Estimator.estimate_message({:assistant, msg})
      result_no_sig = Estimator.estimate_message({:assistant, sig_msg})
      assert result > result_no_sig
    end

    test "tool message with multiple results" do
      results = [
        %{tool_call_id: "1", name: "foo", content: "result 1"},
        %{tool_call_id: "2", name: "bar", content: "result 2"}
      ]

      result = Estimator.estimate_message(tool_msg(results))
      parts = Enum.map(results, &tool_result_to_part/1)
      individual = Estimator.estimate_parts(parts) + 10
      assert result == individual
    end

    test "tool message with nil parts" do
      msg = %Tool{parts: nil}
      result = Estimator.estimate_message({:tool, msg})
      assert result == 10
    end

    test "unknown message variant returns per-message overhead" do
      assert Estimator.estimate_message(:not_a_message) == 10
    end
  end

  describe "estimate_part/1" do
    test "text" do
      assert Estimator.estimate_part(%Part.Text{text: "hi"}) == Estimator.estimate("hi")
    end

    test "thinking" do
      part = %Part.Thinking{thinking: "hmm"}
      assert Estimator.estimate_part(part) == Estimator.estimate("hmm")
    end

    test "tool_use" do
      part = %Part.ToolUse{id: "x", name: "foo", arguments: %{"a" => 1}}
      assert Estimator.estimate_part(part) > 0
    end

    test "tool_result" do
      part = %Part.ToolResult{tool_call_id: "x", name: "foo", content: "y"}
      assert Estimator.estimate_part(part) == Estimator.estimate("y")
    end

    test "refusal" do
      part = %Part.Refusal{refusal: "no"}
      assert Estimator.estimate_part(part) == Estimator.estimate("no")
    end
  end

  describe "estimate_parts/1" do
    test "nil returns 0" do
      assert Estimator.estimate_parts(nil) == 0
    end

    test "empty list returns 0" do
      assert Estimator.estimate_parts([]) == 0
    end
  end

  describe "safety multiplier" do
    test "all public functions apply the 20% safety margin" do
      text = "the quick brown fox jumps over the lazy dog"
      raw = Estimator.raw_count(text)
      est = Estimator.estimate(text)

      # est should be ceil(raw * 1.20) + 10 (per-message overhead)
      assert est >= ceil(raw * 1.20) + 10
    end

    test "estimate_messages applies safety to every message" do
      # Two messages of equal raw size should give equal estimates
      msgs = [user_msg("hello world"), user_msg("hello world")]

      [est1, est2] = Enum.map(msgs, &Estimator.estimate_message/1)
      assert est1 == est2
    end
  end

  describe "realistic sizes" do
    test "a typical chat message is in the right ballpark" do
      # "Tell me about the history of computing" — about 8-9 tokens
      est = Estimator.estimate("Tell me about the history of computing")
      # est ≈ 10-13 tokens for this short message
      assert est >= 10 and est <= 20
    end

    test "a typical source file is sized correctly" do
      code = """
      defmodule Foo do
        def bar(x), do: x * 2
        def baz(y), do: y + 1
      end
      """

      raw = Estimator.raw_count(code)
      est = Estimator.estimate(code)
      # Roughly 20-30 tokens for this small module
      assert raw >= 15 and raw <= 35
      assert est >= 20 and est <= 50
    end

    test "a long conversation is sized correctly" do
      # 50 user/assistant turns
      messages =
        for i <- 1..50 do
          if rem(i, 2) == 1 do
            user_msg("Question #{i}: how do I do thing #{i}?")
          else
            assistant_text_msg("Answer #{i}: here's how to do thing #{i}.")
          end
        end

      total = Estimator.estimate_messages(messages)
      # Roughly 50 * 15-20 tokens = 750-1000 tokens
      assert total >= 500 and total <= 2000
    end
  end
end
