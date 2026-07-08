defmodule Nest.Tokens.ConversationSizeTest do
  @moduledoc """
  Tests for `Nest.Tokens.ConversationSize.size/1`.

  The size is the FLOOR set by the most recent message with a
  real-valued `tokens` field (set by an LLM response) plus
  `Nest.Tokens.Estimator.estimate_messages/1` for the suffix of
  messages without a real value. When no message has `tokens`,
  the entire list is estimated.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Estimator

  # Convenience for a system message with a fixed text.
  defp sys(text) do
    {:system, %System{index: 0, parts: [%Nest.Messages.Part.Text{text: text}]}}
  end

  defp user(text) do
    {:user, %User{index: 1, parts: [%Nest.Messages.Part.Text{text: text}]}}
  end

  describe "size/1" do
    test "empty messages list returns 0" do
      assert ConversationSize.size([]) == 0
    end

    test "no tokens anywhere falls back to estimator" do
      messages = [sys("a"), user("b")]
      assert ConversationSize.size(messages) == Estimator.estimate_messages(messages)
    end

    test "messages with tokens: nil are ignored, estimator fills in" do
      {tag, sys_msg} = sys("a")
      with_nil = {tag, %{sys_msg | tokens: nil}}

      assert ConversationSize.size([with_nil]) == Estimator.estimate_messages([with_nil])
    end

    test "messages with tokens: 0 are ignored, estimator fills in" do
      # Tokens of 0 are meaningless (an LLM call that consumed 0
      # tokens wouldn't be a real call). Skip them so we always
      # have a real-valued floor or fall back to the estimator.
      messages = [
        {:system, %System{index: 0, parts: [], tokens: 0}}
      ]

      assert ConversationSize.size(messages) == Estimator.estimate_messages(messages)
    end

    test "last message has tokens — use it as the floor, no suffix" do
      messages = [
        sys("a"),
        {:user, %User{index: 1, parts: [], tokens: 5500}}
      ]

      assert ConversationSize.size(messages) == 5500
    end

    test "middle message has tokens — find the LAST one, suffix is everything after" do
      messages = [
        sys("a"),
        {:user, %User{index: 1, parts: [], tokens: 5500}},
        {:user, %User{index: 2, parts: [%Nest.Messages.Part.Text{text: "second"}]}},
        {:assistant, %Assistant{index: 3, parts: [%Nest.Messages.Part.Text{text: "ack"}]}}
      ]

      suffix = Enum.drop(messages, 2)
      assert ConversationSize.size(messages) == 5500 + Estimator.estimate_messages(suffix)
    end

    test "multiple messages have tokens — use the LAST one (most recent LLM call wins)" do
      # The second LLM call's tokens supersede the first's. The
      # earlier `tokens` value on the user message is stale but
      # the algorithm ignores it because a later message has a
      # more recent value.
      messages = [
        sys("a"),
        {:user, %User{index: 1, parts: [], tokens: 5500}},
        {:assistant, %Assistant{index: 2, parts: [], tokens: 12_000}},
        {:user, %User{index: 3, parts: [%Nest.Messages.Part.Text{text: "third"}]}}
      ]

      suffix = Enum.drop(messages, 3)
      assert ConversationSize.size(messages) == 12_000 + Estimator.estimate_messages(suffix)
    end

    test "real-value floor captures cache effects the estimator misses" do
      # The real value includes `cache_read_input_tokens` which
      # the cl100k_base estimator doesn't model. A pure estimate
      # would under-count; the real floor is correct.
      {tag, user_msg} = user("short")
      with_real = {tag, %{user_msg | tokens: 12_000}}

      pure_estimate = Estimator.estimate_messages([user("short")])
      assert ConversationSize.size([with_real]) == 12_000
      assert ConversationSize.size([with_real]) > pure_estimate
    end
  end
end
