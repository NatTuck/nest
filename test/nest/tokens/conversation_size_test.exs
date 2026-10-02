defmodule Nest.Tokens.ConversationSizeTest do
  @moduledoc """
  Tests for `Nest.Tokens.ConversationSize.size/1`.

  The size anchors on the newest assistant reply that carries a real
  `usage`: `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens + output_tokens` is the size of the
  conversation including that reply, and the messages after it are
  estimated. Without an anchor, the whole list is estimated.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Estimator

  defp sys(text),
    do: {:system, %System{index: 0, parts: [%Nest.Messages.Part.Text{text: text}]}}

  defp user(text, index \\ 1),
    do: {:user, %User{index: index, parts: [%Nest.Messages.Part.Text{text: text}]}}

  defp assistant(index, usage),
    do:
      {:assistant,
       %Assistant{index: index, parts: [%Nest.Messages.Part.Text{text: "a"}], usage: usage}}

  describe "size/1" do
    test "empty messages list returns 0" do
      assert ConversationSize.size([]) == 0
    end

    test "no usage anywhere falls back to estimator" do
      messages = [sys("a"), user("b")]
      assert ConversationSize.size(messages) == Estimator.estimate_messages(messages)
    end

    test "assistant usage anchors the size (input + cache + output)" do
      messages = [sys("a"), user("b"), assistant(2, %{input_tokens: 5_000, output_tokens: 120})]
      assert ConversationSize.size(messages) == 5_120
    end

    test "cache read/creation tokens are included in the anchor" do
      usage = %{
        input_tokens: 100,
        cache_read_input_tokens: 4_000,
        cache_creation_input_tokens: 500,
        output_tokens: 20
      }

      assert ConversationSize.size([assistant(1, usage)]) == 4_620
    end

    test "suffix after the newest anchor is estimated" do
      messages = [
        sys("a"),
        assistant(1, %{input_tokens: 5_000, output_tokens: 100}),
        user("later", 2),
        {:assistant, %Assistant{index: 3, parts: [%Nest.Messages.Part.Text{text: "reply"}]}}
      ]

      suffix = Enum.drop(messages, 2)
      assert ConversationSize.size(messages) == 5_100 + Estimator.estimate_messages(suffix)
    end

    test "the newest anchor wins over older ones" do
      messages = [
        assistant(1, %{input_tokens: 5_000, output_tokens: 100}),
        user("later", 2),
        assistant(3, %{input_tokens: 12_000, output_tokens: 200})
      ]

      assert ConversationSize.size(messages) == 12_200
    end

    test "string-keyed (restored) usage is read the same as atom-keyed" do
      usage = %{"input_tokens" => 1_000, "cache_read_input_tokens" => 500, "output_tokens" => 30}
      assert ConversationSize.size([assistant(1, usage)]) == 1_530
    end

    test "missing output_tokens falls back to input+cache and estimates the reply" do
      messages = [sys("a"), assistant(1, %{input_tokens: 5_000, cache_read_input_tokens: 100})]
      anchor = Enum.at(messages, 1)
      assert ConversationSize.size(messages) == 5_100 + Estimator.estimate_messages([anchor])
    end

    test "usage without a positive input_tokens is ignored" do
      messages = [assistant(1, %{input_tokens: 0, output_tokens: 30})]
      assert ConversationSize.size(messages) == Estimator.estimate_messages(messages)
    end
  end
end
