defmodule NestWeb.AgentChannel.Sync do
  @moduledoc """
  Bounded `chat:sync` reply shaping for the agent channel.

  A `chat:sync` reply carries every message the client missed, which for a
  long-lived agent can be a very large batch. The reply is capped by JSON wire
  size so a single websocket frame stays bounded; the client re-syncs for the
  rest.

  The cap is applied in a **single pass**, and only the messages the reply
  keeps are formatted. That is the whole point of this module: formatting every
  message above `lastIndex` on every batch made a cold-cache drain quadratic in
  the size of the active window (issue #52). A 500-message / 15 MB window took
  ~240 sequential batches, and each one re-formatted and re-encoded every
  message it had already sent. With a single pass a reply costs O(batch) in
  formatting, so the drain costs O(payload) overall.

  Extracted from `NestWeb.AgentChannel` so that module stays within the
  file-length budget.
  """

  alias Nest.Messages.Message

  @doc """
  Take the prefix of `messages` whose combined JSON wire size is ≤ `limit`
  bytes, formatting only the messages it keeps.

  `messages` is the agent's active messages above `lastIndex`, ascending, in
  the internal `{:role, struct}` form. Always returns at least one element when
  the input is non-empty, regardless of that element's individual size, so one
  oversized message cannot wedge the drain. Returns `{kept, total_bytes}`,
  where `kept` is a list of wire maps.

  The formatter is injectable so a test can observe exactly which messages were
  formatted — the property this module exists to guarantee.
  """
  @spec take([Message.t()], non_neg_integer(), (Message.t() -> map())) ::
          {[map()], non_neg_integer()}
  def take(messages, limit, format \\ &Message.to_json/1)

  def take([first | rest], limit, format) do
    first_json = format.(first)
    first_size = json_wire_size(first_json)

    take_while_under(rest, limit - first_size, [first_json], first_size, format)
  end

  def take([], _limit, _format), do: {[], 0}

  defp take_while_under([], _remaining, acc, total, _format),
    do: {Enum.reverse(acc), total}

  defp take_while_under([next | rest], remaining, acc, total, format) do
    # A message's wire size is only knowable once it is formatted, and we must
    # not format messages the reply will not carry. So each step formats one
    # candidate: it is either kept (and paid for) or ends the batch, which
    # costs one extra format per reply — not one per remaining message.
    next_json = format.(next)
    next_size = json_wire_size(next_json)

    if next_size <= remaining do
      take_while_under(rest, remaining - next_size, [next_json | acc], total + next_size, format)
    else
      {Enum.reverse(acc), total}
    end
  end

  # The JSON byte size for a serialised message map, which is the size the
  # reply contributes to its frame.
  defp json_wire_size(map) when is_map(map) do
    map |> Jason.encode!() |> byte_size()
  end
end
