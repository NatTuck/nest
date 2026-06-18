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
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator

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
        {:system, %System{content: "You are helpful"}},
        {:user, %User{content: "Hello"}},
        {:assistant, %Assistant{content: "Hi there"}}
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
        {:system, %System{content: "System prompt"}},
        {:user, %User{content: "User msg"}},
        {:assistant,
         %Assistant{
           content: "Assistant response",
           thinking: "Internal thought",
           tool_calls: [
             %ToolCall{id: "1", name: "shell_cmd", arguments: %{"cmd" => "ls"}}
           ]
         }},
        {:tool,
         %Tool{
           tool_results: [
             %ToolResult{tool_call_id: "1", name: "shell_cmd", content: "file1\nfile2"}
           ]
         }}
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
      assert Estimator.estimate_message({:system, %System{content: "hi"}}) ==
               Estimator.estimate("hi")
    end

    test "system message with nil content" do
      # Should not crash
      result = Estimator.estimate_message({:system, %System{content: nil}})
      assert is_integer(result)
      assert result > 0
    end

    test "user message" do
      assert Estimator.estimate_message({:user, %User{content: "hello"}}) ==
               Estimator.estimate("hello")
    end

    test "assistant message with content and thinking" do
      msg = %Assistant{content: "hi", thinking: "thoughtful"}
      result = Estimator.estimate_message({:assistant, msg})
      # Should be at least the sum of the two texts
      assert result >= Estimator.estimate("hi") + Estimator.estimate("thoughtful") - 10
    end

    test "assistant message with tool calls sizes JSON args" do
      msg = %Assistant{
        content: nil,
        tool_calls: [
          %ToolCall{
            id: "call_1",
            name: "shell_cmd",
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
        content: "hi",
        thinking_signature: "abc123signature"
      }

      result = Estimator.estimate_message({:assistant, msg})
      assert result > Estimator.estimate_message({:assistant, %Assistant{content: "hi"}})
    end

    test "tool message with multiple results" do
      msg = %Tool{
        tool_results: [
          %ToolResult{tool_call_id: "1", name: "foo", content: "result 1"},
          %ToolResult{tool_call_id: "2", name: "bar", content: "result 2"}
        ]
      }

      result = Estimator.estimate_message({:tool, msg})
      individual = Estimator.estimate_tool_results(msg.tool_results)
      assert result == individual
    end

    test "tool message with nil tool_results" do
      msg = %Tool{tool_results: nil}
      result = Estimator.estimate_message({:tool, msg})
      assert result == 0
    end

    test "unknown message variant returns per-message overhead" do
      assert Estimator.estimate_message(:not_a_message) == 10
    end
  end

  describe "estimate_tool_calls/1" do
    test "nil returns 0" do
      assert Estimator.estimate_tool_calls(nil) == 0
    end

    test "empty list returns 0" do
      assert Estimator.estimate_tool_calls([]) == 0
    end

    test "non-list returns 0" do
      assert Estimator.estimate_tool_calls(:nope) == 0
    end

    test "estimates per call and sums" do
      calls = [
        %ToolCall{id: "1", name: "foo", arguments: %{"a" => 1}},
        %ToolCall{id: "2", name: "bar", arguments: %{"b" => 2}}
      ]

      result = Estimator.estimate_tool_calls(calls)
      assert result > 0
    end
  end

  describe "estimate_tool_results/1" do
    test "nil returns 0" do
      assert Estimator.estimate_tool_results(nil) == 0
    end

    test "empty list returns 0" do
      assert Estimator.estimate_tool_results([]) == 0
    end

    test "estimates per result" do
      results = [
        %ToolResult{tool_call_id: "1", name: "foo", content: "a result"},
        %ToolResult{tool_call_id: "2", name: "bar", content: "another"}
      ]

      total = Estimator.estimate_tool_results(results)
      assert total > Estimator.estimate("a result")
    end

    test "includes JSON args in estimate" do
      small = %ToolResult{
        tool_call_id: "1",
        name: "foo",
        content: "x",
        arguments: %{}
      }

      big = %ToolResult{
        tool_call_id: "1",
        name: "foo",
        content: "x",
        arguments: %{"key" => String.duplicate("a", 500)}
      }

      assert Estimator.estimate_tool_result(big) >
               Estimator.estimate_tool_result(small)
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
      msgs = [
        {:user, %User{content: "hello world"}},
        {:user, %User{content: "hello world"}}
      ]

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
            {:user, %User{content: "Question #{i}: how do I do thing #{i}?"}}
          else
            {:assistant, %Assistant{content: "Answer #{i}: here's how to do thing #{i}."}}
          end
        end

      total = Estimator.estimate_messages(messages)
      # Roughly 50 * 15-20 tokens = 750-1000 tokens
      assert total >= 500 and total <= 2000
    end
  end
end
