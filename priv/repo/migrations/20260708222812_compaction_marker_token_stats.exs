defmodule Nest.Repo.Migrations.CompactionMarkerTokenStats do
  @moduledoc """
  Records token-count stats on the `role: "compaction"` marker
  rows so the chat UI can render how much a compaction actually
  saved.

  ## Why

  The marker (`compaction_archived_count` carrying the count of
  archived messages) is the data the CompactionMarker divider
  renders today. The new columns carry the *token* view of the
  same boundary: tokens before compaction (sum of the messages
  being moved to history) and tokens after (sum of the new
  compacted state).

  The chip layout becomes:

      Compaction: 18,432 tokens compacted to 4,096
      (saved 14,336)

  Both columns are nullable — non-compaction rows don't carry
  stats. `compaction_tokens_compacted_to` is the post-compaction
  state at the marker boundary, NOT the running total of
  subsequent compactions; each compactor pass writes its own
  pre/post pair.

  ## Schema impact

  Two new INTEGER columns on `messages`. No new indexes (the
  marker is always looked up by `(agent_id, message_index)` which
  is already unique). No data backfill needed — pre-existing
  marker rows have NULL for both (the UI shows
  "context compacted (N archived)" without token stats).

  Wired through:
    * `Nest.Persistence.record_compaction/5` (new arity taking
      pre/post totals; old 3-arity preserved as delegator)
    * `Nest.Agents.PersistedMessage.{from_runtime/2, to_runtime/1,
      changeset/2}`
    * `Nest.Messages.Compaction` struct + `to_json/1`
    * `Nest.Agents.Agent.Broadcasts.compaction/3` (the
      `chat:compaction` payload carries both)
    * `Nest.Agents.Agent.CompactionLifecycle.apply/2` computes
      the totals at compaction time via `Estimator.estimate_messages/1`
  """

  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :compaction_tokens_compacted, :integer
      add :compaction_tokens_compacted_to, :integer
    end
  end
end
