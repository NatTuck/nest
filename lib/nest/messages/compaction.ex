defmodule Nest.Messages.Compaction do
  @moduledoc """
  A divider message marking the boundary between archived and
  active history.

  When the agent compacts, the previous `messages` are appended
  to `history` with a `Compaction` marker in between. The marker
  is rendered in the chat UI as a divider with a "show N archived
  messages" expand button, plus per-marker token stats.

  The marker does NOT appear in the LLM-visible `messages` list;
  it lives only in `history`.

  ## Fields

  * `index` — message index the marker occupies in the
    monotonic sequence.
  * `archived_count` — number of messages that were moved to
    history at this boundary. Drives the
    "N earlier messages archived" header.
  * `tokens_compacted` / `tokens_compacted_to` — token-count
    stats computed at compaction time via
    `Nest.Tokens.Estimator.estimate_messages/1`. Drives the
    "Compaction: X tokens compacted to Y" sub-line. Both
    optional — `nil` for pre-existing marker rows whose stats
    weren't recorded.
  * `occurred_at` — wall-clock time of the compaction.
  * `metadata` — placeholder for future marker metadata.
  """

  defstruct [
    :index,
    :archived_count,
    :tokens_compacted,
    :tokens_compacted_to,
    :occurred_at,
    :metadata
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          archived_count: non_neg_integer(),
          tokens_compacted: non_neg_integer() | nil,
          tokens_compacted_to: non_neg_integer() | nil,
          occurred_at: DateTime.t() | nil,
          metadata: map() | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = marker) do
    %{
      "index" => marker.index,
      "role" => "compaction",
      "archivedCount" => marker.archived_count,
      "tokensCompacted" => marker.tokens_compacted,
      "tokensCompactedTo" => marker.tokens_compacted_to,
      "occurredAt" => format_timestamp(marker.occurred_at),
      "apiLogs" => []
    }
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: other
end
