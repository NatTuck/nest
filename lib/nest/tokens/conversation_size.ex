defmodule Nest.Tokens.ConversationSize do
  @moduledoc """
  Compute the current conversation size in tokens, using real
  values from prior LLM responses where available and the
  estimator only for the suffix that hasn't been seen by an LLM
  yet.

  Each `Message.t()` carries a `tokens` field — populated by
  `LLMStreamHandler.mark_last_message_tokens/2` after every
  assistant response. The field is the total tokens
  (`input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens`) the LLM consumed when this
  message was the LAST in its input. Walking the message list
  backwards and finding the most recent non-nil `tokens` gives
  us a real-valued FLOOR for the current conversation size.

  The suffix of messages after that point hasn't been seen by
  an LLM yet (no real value), so we add the estimator's
  projection of just those messages. The estimator applies a
  20% safety multiplier (see `Nest.Tokens.Estimator`); the
  suffix estimate is a slight upper bound.

  ## Why this design

  Previously every context decision used
  `Estimator.estimate_messages/1` on the full message list. The
  estimate is `cl100k_base` + 1.20× and misses two things:

    * **Cache effects**: a call that reads a large cache has
      `input_tokens: 5000` but `cache_read_input_tokens: 5000`,
      so the real value is `context_input_tokens: 10000`. The
      estimate only sees the visible text.
    * **Provider-specific tokenization**: Anthropic and OpenAI
      tokenize slightly differently. The estimate is a proxy.

  Storing the real value on the message itself (rather than in
  a parallel `usage_totals` map) makes the data flow obvious:
  walk the list, take the floor from the last known point,
  estimate the rest. The cumulative session totals (`total_*`)
  still live in `usage_totals` because they're session-wide sums,
  not conversation-state.

  ## Examples

      iex> alias Nest.Tokens.ConversationSize
      iex> ConversationSize.size([])
      0

      iex> ConversationSize.size([{:system, %Nest.Messages.System{parts: [%Nest.Messages.Part.Text{text: "Hi"}]}}])
      # estimator value (~3 tokens, plus overhead)

      iex> msgs = [
      ...>   {:system, %Nest.Messages.System{}},
      ...>   {:user, %Nest.Messages.User{tokens: 5500, parts: []}}
      ...> ]
      iex> ConversationSize.size(msgs)
      # 5500 (real floor) + estimate(suffix after user)
  """

  alias Nest.Tokens.Estimator

  @type message :: {atom(), map()}

  @doc """
  The current conversation size in tokens. Walks the message
  list backwards looking for the most recent `tokens` field
  with a non-nil integer; uses it as the floor and adds the
  estimator's projection of the suffix. If no message has
  `tokens` set, returns the estimator's projection of the
  full list.
  """
  @spec size([message()]) :: non_neg_integer()
  def size([]), do: 0

  def size(messages) when is_list(messages) do
    case last_index_with_tokens(messages) do
      {:ok, idx, real_tokens} ->
        suffix = Enum.drop(messages, idx + 1)
        real_tokens + Estimator.estimate_messages(suffix)

      :none ->
        Estimator.estimate_messages(messages)
    end
  end

  # Walk backwards and find the most recent message with a
  # non-nil integer `tokens` field. Returns `:none` if none
  # of the messages have a real value. `original_idx` comes
  # straight from `Enum.with_index/1` — it's the position in
  # the original messages list, not the reversed position.
  defp last_index_with_tokens(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, original_idx} ->
      case msg do
        {_, %{tokens: n}} when is_integer(n) and n > 0 ->
          {:ok, original_idx, n}

        _ ->
          nil
      end
    end) || :none
  end
end
