defmodule Nest.Tokens.RequestSize do
  @moduledoc """
  The byte size of a request's message list, and the ceiling new media is
  refused at.

  ## Why tokens are not enough

  Media is priced in tokens and bounded by nothing in bytes. An image costs
  `Estimator.estimate_media_ceiling/1` — 4,096 tokens whatever its size — and
  that is *correct* for what it measures: every provider downsamples to its own
  ceiling before billing, so the ceiling is the true model-visible cost. It is
  useless as a size metric. The same 9.4 MB is 4,096 tokens as an image and
  ~2.85M tokens as text — a 700× difference — so a conversation can be tiny by
  the only number the compaction trigger reads and enormous on the wire.

  DeepSeek documents a **48 MiB request body limit** and a **32 MiB per-image
  inline limit**. `max_bytes/0` sits well under both, and under the point at
  which the compactor's own request — which carries the full conversation —
  would be rejected, since that request is what makes an over-limit agent
  unrecoverable rather than merely slow.

  ## This is interim

  Issue #142 tracks the real fix: the provider Files API, where an image is
  uploaded once and referenced by id, so the body carries a pointer and the
  message bytes never change. Until then, refusing a *new* image is the only
  lever that does not mutate already-sent messages, and so the only one that
  costs no prefix-cache invalidation. Dropping media from history would work
  too, but it would break the cached prefix every turn, which the project's
  rules do not allow outside compaction.
  """

  # 16 MB. Deliberately below the 48 MiB body limit so the compaction request —
  # which carries the whole conversation — still fits, and deliberately above
  # any text-only conversation: at 3.3 MB per 1M tokens, reaching 16 MB of text
  # would take ~4.8M tokens, so this can only ever fire on media.
  @max_bytes 16_000_000

  @doc "The byte ceiling a projected request must stay under."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  The byte size of a message list, as it will be sent.

  Every binary a part carries is counted, so base64 media — by far the dominant
  term — cannot be missed, and a part type added later is counted without this
  function changing. Deliberately an upper bound rather than a serialised size:
  it is a gate, and over-counting refuses slightly early where under-counting
  would let a request through that the provider then rejects.
  """
  @spec bytes([term()]) :: non_neg_integer()
  def bytes(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + message_bytes(message) end)
  end

  @doc """
  Whether a request of `messages` plus `media_bytes` of new media stays under
  the ceiling.

  The one predicate both gates use — `file-read`'s per-call refusal and
  `BatchSizer.preflight`'s batch refusal — so a change to the rule happens in
  one place rather than two that could disagree.
  """
  @spec within?([term()], non_neg_integer()) :: boolean()
  def within?(messages, media_bytes) when is_list(messages) and is_integer(media_bytes) do
    bytes(messages) + media_bytes <= @max_bytes
  end

  @doc """
  The wire size of a media part holding `file_bytes` decoded bytes.

  Base64 is four characters per three bytes, rounded up, and the characters are
  ASCII, so this is also the byte cost.
  """
  @spec media_wire_bytes(non_neg_integer()) :: non_neg_integer()
  def media_wire_bytes(file_bytes) when is_integer(file_bytes) and file_bytes >= 0 do
    div(file_bytes + 2, 3) * 4
  end

  defp message_bytes({_role, message}), do: message_bytes(message)

  defp message_bytes(%{parts: parts}) when is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc -> value_bytes(part, acc) end)
  end

  defp message_bytes(%{content: content}), do: value_bytes(content, 0)
  defp message_bytes(_message), do: 0

  defp value_bytes(value, acc) when is_binary(value), do: acc + byte_size(value)

  # A struct is a map, so this clause has to come first: `Map.from_struct/1`
  # drops the `__struct__` key, and a nested struct (a tool call's arguments,
  # say) is then walked like any other map.
  defp value_bytes(value, acc) when is_struct(value) do
    value
    |> Map.from_struct()
    |> value_bytes(acc)
  end

  defp value_bytes(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {_key, inner}, inner_acc -> value_bytes(inner, inner_acc) end)
  end

  defp value_bytes(value, acc) when is_list(value) do
    Enum.reduce(value, acc, fn inner, inner_acc -> value_bytes(inner, inner_acc) end)
  end

  defp value_bytes(_value, acc), do: acc
end
