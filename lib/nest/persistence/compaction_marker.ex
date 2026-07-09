defmodule Nest.Persistence.CompactionMarker do
  @moduledoc """
  Marker-row persistence for `role: "compaction"` boundaries.

  Extracted from `Nest.Persistence` to keep that module under
  the 500-line credo cap. Owns the marker INSERT and the
  `agents.last_compaction_index` bump that together commit in
  one transaction.

  ## Why split out

  `record_compaction/5` plus its private helpers (`insert_marker/6`,
  `maybe_put_compaction_token/3`, `bump_boundary/3`) add up to ~80
  lines of cohesion that don't share state with the agent / message
  loaders (which is the rest of `Nest.Persistence`'s public API).
  Keeping them here means adding token-stats columns doesn't blow
  the parent module out of proportion.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Repo

  @doc """
  Insert a `role: "compaction"` marker row at `marker_index`
  and bump `agents.last_compaction_index` to match. Both
  writes happen inside one `Repo.transaction` so the marker
  row and the boundary pointer commit together — a partial
  commit would produce a wrong partition on the next restore
  (rows that should be `messages` would land in `history` or
  vice versa).

  `tokens_compacted` and `tokens_compacted_to` are the
  pre/post totals computed by the caller at compaction time
  (via `Nest.Tokens.Estimator.estimate_messages/1`). Either
  may be nil for legacy callers or for compactor paths that
  don't have both numbers available — the columns are
  nullable so the marker row still inserts.

  Returns the new marker row on success, or
  `{:error, term()}` on failure.
  """
  @spec record(
          agent_id,
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) ::
          {:ok, PersistedMessage.t()} | {:error, term()}
        when agent_id: integer()
  def record(agent_id, marker_index, archived_count, tokens_compacted, tokens_compacted_to) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      insert_marker(
        agent_id,
        marker_index,
        archived_count,
        tokens_compacted,
        tokens_compacted_to,
        now
      )
      |> bump_boundary(agent_id, marker_index)
    end)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # Insert the marker row. On failure, roll back the
  # surrounding transaction.
  defp insert_marker(
         agent_id,
         marker_index,
         archived_count,
         tokens_compacted,
         tokens_compacted_to,
         now
       ) do
    base_attrs = %{
      agent_id: agent_id,
      message_index: marker_index,
      role: "compaction",
      content: %{"parts" => []},
      inserted_at: now,
      compaction_archived_count: archived_count,
      compaction_occurred_at: now
    }

    attrs =
      base_attrs
      |> maybe_put_compaction_token(:compaction_tokens_compacted, tokens_compacted)
      |> maybe_put_compaction_token(:compaction_tokens_compacted_to, tokens_compacted_to)

    case %PersistedMessage{}
         |> PersistedMessage.changeset(attrs)
         |> Repo.insert() do
      {:ok, marker_row} ->
        marker_row

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Token stats are optional (nullable columns). Only set the
  # key when the caller provided a number — `nil` means
  # "no stats recorded" and the column defaults stay unset.
  defp maybe_put_compaction_token(attrs, _key, nil), do: attrs
  defp maybe_put_compaction_token(attrs, key, value), do: Map.put(attrs, key, value)

  # Bump the boundary column so the next `load_messages/1`
  # caller partitions correctly on restore. Returns the
  # marker row unchanged so the transaction closure flow
  # stays linear.
  defp bump_boundary(marker_row, agent_id, marker_index) do
    from(a in PersistedAgent, where: a.id == ^agent_id)
    |> Repo.update_all(set: [last_compaction_index: marker_index])

    marker_row
  end
end
