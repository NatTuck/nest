defmodule Nest.Tokens.ConversationSize do
  @moduledoc """
  Compute the current conversation size in tokens, using the real
  values the provider reported for the most recent assistant reply
  and the estimator only for the messages after it.

  Every assistant message carries the LLM response's `usage` (set by
  `Nest.Agents.Agent.ChatTurn.Messages.assistant/1` and persisted with
  the message). The provider-reported input count is the size of the
  context that produced that reply; adding the reply's own
  `output_tokens` gives the size of the conversation *including* that
  reply:

      reply_value = input_tokens + cache_read_input_tokens
                  + cache_creation_input_tokens + output_tokens

  Walking the list backwards to the newest assistant with a usable
  `usage` gives a real FLOOR; the messages after it (which the LLM has
  not seen yet) are projected with `Estimator`. This is the "REAL"
  basis used by `Nest.Tokens.Budget` and the compaction reserve
  invariant.

  ## Why the reply value

  The `usage` arrives with the reply, and the reply is the last
  message the call produced, so anchoring on the reply means no
  consumer has to estimate the reply itself. Anchoring on the
  *request* (the input tail) would leave the reply to the estimator
  and require mutating an already-committed message. Reading the
  reply's own committed `usage` keeps the basis immutable and real.

  ## Restored vs live key shape

  Live `usage` maps have atom keys (`:input_tokens`); the value
  restored from the JSONB column has string keys (`"input_tokens"`).
  `usage_get/2` normalizes both.

  ## Examples

      iex> alias Nest.Tokens.ConversationSize
      iex> ConversationSize.size([])
      0

      iex> msgs = [
      ...>   {:assistant, %Nest.Messages.Assistant{usage: %{input_tokens: 5500, output_tokens: 120}}}
      ...> ]
      iex> ConversationSize.size(msgs)
      # 5620 (real reply_value) + 0 (no suffix)
  """

  alias Nest.Tokens.Estimator

  @type message :: {atom(), map()}

  @doc """
  The current conversation size in tokens. Anchors on the newest
  assistant message that carries a real `usage`, using
  `input + cache_read + cache_creation + output` as a real floor and
  estimating only the messages after it. Without an anchor, returns the
  estimator's projection of the full list.
  """
  @spec size([message()]) :: non_neg_integer()
  def size([]), do: 0

  def size(messages) when is_list(messages) do
    case last_usage_anchor(messages) do
      {:ok, value, suffix} -> value + Estimator.estimate_messages(suffix)
      :none -> Estimator.estimate_messages(messages)
    end
  end

  # Walk backwards for the newest message whose struct carries a usable
  # `usage` (assistants only). Returns `{:ok, value, suffix_messages}`
  # where `suffix_messages` excludes the anchor when its value already
  # counts it (i.e. it has `output_tokens`), or includes it otherwise.
  defp last_usage_anchor(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} -> anchor_with_suffix(msg, messages, idx) end) || :none
  end

  defp anchor_with_suffix(msg, messages, idx) do
    case usage_anchor(msg) do
      nil -> nil
      {value, include_self?} -> {:ok, value, suffix(messages, idx, include_self?)}
    end
  end

  defp suffix(messages, idx, true), do: Enum.drop(messages, idx)
  defp suffix(messages, idx, false), do: Enum.drop(messages, idx + 1)

  # The real reply_value for a message with `usage`, plus whether the
  # suffix should re-include the message itself (when `output_tokens` is
  # unavailable, so the reply is not counted by the value and must be
  # estimated).
  defp usage_anchor({_, %{usage: usage}}) when is_map(usage) do
    case usage_get(usage, :input_tokens) do
      n when is_integer(n) and n > 0 ->
        output_anchor(n + cache_tokens(usage), usage_get(usage, :output_tokens))

      _ ->
        nil
    end
  end

  defp usage_anchor(_), do: nil

  defp cache_tokens(usage) do
    (usage_get(usage, :cache_read_input_tokens) || 0) +
      (usage_get(usage, :cache_creation_input_tokens) || 0)
  end

  defp output_anchor(base, out) when is_integer(out) and out >= 0, do: {base + out, false}
  defp output_anchor(base, _), do: {base, true}

  # `usage` keys are atoms when live and strings when restored from JSON.
  defp usage_get(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
  end
end
