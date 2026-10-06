defmodule NestWeb.AgentChannel.Sync do
  @moduledoc """
  Bounded `chat:sync` reply shaping for the agent channel.

  A `chat:sync` reply carries every message the client missed, which for
  a long-lived agent can be a very large batch. The reply is capped by
  JSON wire size so a single websocket frame stays bounded; the client
  re-syncs for the rest. Extracted from `NestWeb.AgentChannel` so that
  module stays within the file-length budget.
  """

  @doc """
  Take a prefix of `messages` whose combined JSON wire size is
  ≤ `limit` bytes. Always returns at least one element when the
  input is non-empty, regardless of its individual size. Returns
  `{kept, total_bytes}`.
  """
  @spec truncate([map()], non_neg_integer()) :: {[map()], non_neg_integer()}
  def truncate([first | rest], limit) do
    first_size = json_wire_size(first)

    take_while_under(rest, limit - first_size, [first], first_size)
  end

  def truncate([], _limit), do: {[], 0}

  defp take_while_under([], _remaining, acc, total), do: {Enum.reverse(acc), total}

  defp take_while_under([next | rest], remaining, acc, total) do
    next_size = json_wire_size(next)

    if next_size <= remaining do
      take_while_under(rest, remaining - next_size, [next | acc], total + next_size)
    else
      {Enum.reverse(acc), total}
    end
  end

  # Estimate of the JSON byte size for a serialised message map.
  # Uses the external term size of the Jason-encoded binary as a
  # cheap proxy for the actual wire byte count.
  defp json_wire_size(map) when is_map(map) do
    map |> Jason.encode!() |> byte_size()
  end
end
