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
    test "counts ASCII, empty, long, and non-binary input" do
      # Sanity: "Hello, world!" is exactly 4 tokens in cl100k_base
      assert Estimator.raw_count("Hello, world!") == 4

      assert Estimator.raw_count("") == 0

      assert Estimator.raw_count(nil) == 0
      assert Estimator.raw_count(123) == 0

      long = String.duplicate("a", 1000)
      # Each character is at most 1 token; 1000 chars ≈ 1000 tokens
      # for all-same-char (usually encoded as 1 token in BPE).
      n = Estimator.raw_count(long)
      assert is_integer(n)
      assert n > 0
    end

    test "invalid UTF-8 falls back to a byte estimate instead of crashing" do
      # Gzip magic bytes — the shape that crashed the tool loop when a
      # shell command dumped a compressed download to stdout.
      binary = <<0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00>>

      assert Estimator.raw_count(binary) == div(byte_size(binary) + 3, 4)

      # A lone invalid byte also falls back without raising.
      assert is_integer(Estimator.raw_count(<<0xFF, 0xFE, 0x41>>))
    end
  end

  describe "fallback_or_reraise/4" do
    test "falls back when the tokenizer is loaded and re-raises when it is not" do
      # The rescue body of the tokenizer call, with the `loaded?` boolean
      # passed in so both branches are reachable without touching
      # `:persistent_term`.
      error = %ArgumentError{message: "genuine tokenization failure"}
      text = "the quick brown fox"

      # Loaded: a genuine tokenization failure falls back to chars / 4.
      assert Estimator.fallback_or_reraise(text, true, error, []) == 5

      # Unloaded: that is a boot-ordering bug, not a tokenization
      # failure, so it has to surface instead of becoming a wrong count.
      assert_raise ArgumentError, "genuine tokenization failure", fn ->
        Estimator.fallback_or_reraise(text, false, error, [])
      end
    end
  end

  describe "estimate/1 (string)" do
    test "always overestimates raw count, with at least the 20% safety margin" do
      raw = Estimator.raw_count("Hello, world!")
      # The safety multiplier is 1.20, plus per-message overhead of 10.
      est = Estimator.estimate("Hello, world!")
      assert est >= ceil(raw * 1.20)
      # And the +10 overhead pushes it above the raw value
      assert est > raw

      for t <- ["hi", "Hello, world!", "the quick brown fox", ""] do
        t_raw = Estimator.raw_count(t)
        t_est = Estimator.estimate(t)
        assert t_est >= t_raw, "expected estimate >= raw for #{inspect(t)}"
      end
    end

    test "returns the overhead for non-binary input and estimates invalid UTF-8 without raising" do
      assert Estimator.estimate(nil) == 10
      assert Estimator.estimate(123) == 10

      binary = <<0x1F, 0x8B, 0x08, 0x00>>

      assert is_integer(Estimator.estimate(binary))
      assert Estimator.estimate(binary) > 10
    end
  end

  describe "estimate_bytes/1" do
    test "scales with byte size, applies the safety margin, and returns overhead for zero bytes" do
      small = Estimator.estimate_bytes(4_000)
      large = Estimator.estimate_bytes(40_000)

      assert large > small
      # ~4 bytes/token, +20% safety, +10 per-message overhead.
      assert large == ceil(div(40_000, 4) * 1.20) + 10

      assert Estimator.estimate_bytes(0) == 10
    end
  end

  describe "estimate_messages/1" do
    test "sums per-message estimates across all message types" do
      simple = [
        sys_msg("You are helpful"),
        user_msg("Hello"),
        assistant_text_msg("Hi there")
      ]

      all_types = [
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

      for messages <- [simple, all_types] do
        total = Estimator.estimate_messages(messages)
        # Sanity: at least some tokens for each message
        assert total > 0
        # And it's the sum of individual estimates
        individual = Enum.map(messages, &Estimator.estimate_message/1) |> Enum.sum()
        assert total == individual
      end
    end

    test "returns 0 for non-list and empty input" do
      assert Estimator.estimate_messages(nil) == 0
      assert Estimator.estimate_messages([]) == 0
    end
  end

  describe "estimate_message/1" do
    test "system and user messages are the parts estimate plus overhead" do
      assert Estimator.estimate_message(sys_msg("hi")) ==
               Estimator.estimate_parts([%Part.Text{text: "hi"}]) + 10

      assert Estimator.estimate_message(user_msg("hello")) ==
               Estimator.estimate_parts([%Part.Text{text: "hello"}]) + 10

      # A system message with nil content should not crash
      result = Estimator.estimate_message({:system, %System{parts: nil}})
      assert is_integer(result)
      assert result > 0
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

    test "tool messages sum their result parts, and nil parts give the overhead" do
      results = [
        %{tool_call_id: "1", name: "foo", content: "result 1"},
        %{tool_call_id: "2", name: "bar", content: "result 2"}
      ]

      result = Estimator.estimate_message(tool_msg(results))
      parts = Enum.map(results, &tool_result_to_part/1)
      individual = Estimator.estimate_parts(parts) + 10
      assert result == individual

      assert Estimator.estimate_message({:tool, %Tool{parts: nil}}) == 10
    end

    test "unknown message variant returns per-message overhead" do
      assert Estimator.estimate_message(:not_a_message) == 10
    end
  end

  describe "estimate_part/1" do
    test "sizes every part type" do
      assert Estimator.estimate_part(%Part.Text{text: "hi"}) == Estimator.estimate("hi")

      assert Estimator.estimate_part(%Part.Thinking{thinking: "hmm"}) ==
               Estimator.estimate("hmm")

      assert Estimator.estimate_part(%Part.ToolUse{id: "x", name: "foo", arguments: %{"a" => 1}}) >
               0

      assert Estimator.estimate_part(%Part.ToolResult{
               tool_call_id: "x",
               name: "foo",
               content: "y"
             }) ==
               Estimator.estimate("y")

      assert Estimator.estimate_part(%Part.Refusal{refusal: "no"}) == Estimator.estimate("no")
    end
  end

  describe "estimate_parts/1" do
    test "returns 0 for nil and for the empty list" do
      assert Estimator.estimate_parts(nil) == 0
      assert Estimator.estimate_parts([]) == 0
    end
  end

  describe "safety multiplier" do
    test "applies the 20% margin to strings and to every message" do
      text = "the quick brown fox jumps over the lazy dog"
      raw = Estimator.raw_count(text)
      est = Estimator.estimate(text)

      # est should be ceil(raw * 1.20) + 10 (per-message overhead)
      assert est >= ceil(raw * 1.20) + 10

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
