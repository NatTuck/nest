defmodule Nest.Messages.Compaction do
  @moduledoc """
  A divider message marking the boundary between archived and
  active history.

  When the agent compacts, the previous `messages` are appended
  to `history` with a `Compaction` marker in between. The marker
  is rendered in the chat UI as a divider with a "show N archived
  messages" expand button.

  The marker does NOT appear in the LLM-visible `messages` list;
  it lives only in `history`. Its `archived_count` field tells the
  UI how many messages it represents.
  """

  defstruct [:index, :archived_count, :occurred_at, :metadata]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          archived_count: non_neg_integer(),
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
      "occurredAt" => format_timestamp(marker.occurred_at),
      "apiLogs" => []
    }
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: other
end
