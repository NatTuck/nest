defmodule Nest.Repo.Migrations.UnifyMessageSequence do
  @moduledoc """
  Brings `messages` to an append-only, immutable shape and adds the
  boundary column on `agents` that drives the active/history partition.

  ## Why

  Today the compaction cycle carries `archived_at` on the `messages`
  rows that get compacted away. That row UPDATE made `messages`
  mutable at the storage layer and conflated two competing sources
  of truth (the column, and the in-memory pruning in
  `CompactionLifecycle.apply/2`). The `state.chat_state.history`
  slice was never restored on BEAM restart; the boundary itself
  was fine-grained enough that the UI's "collapsible history"
  feature silently dropped rows.

  ## What it does

  1. `ALTER TABLE agents ADD COLUMN last_compaction_index INTEGER NOT NULL DEFAULT -1`.
     `state.chat_state.messages = messages WHERE message_index > agents.last_compaction_index`.
     `-1` sentinel means "no compaction has happened; the entire
     sequence, including the system prompt at index 0, is in
     `messages`."

  2. One UPDATE per agent to backfill from existing
     `role: 'compaction'` marker rows. Idempotent — `MAX` with
     `COALESCE(..., -1)`.

  3. `DROP INDEX messages_agent_id_archived_at_index` —
     no longer needed.

  4. `ALTER TABLE messages DROP COLUMN archived_at`. The
     boundary is now on the agents row.

  No data is lost. The `archived_at` bit is fully derivable from
  the existing `role: 'compaction'` marker rows; `load_messages/1`
  (was `load_active_messages/1`) continues to return the same set
  as before for new compactions.
  """

  use Ecto.Migration

  def change do
    # 1. Add the boundary column on agents.
    alter table(:agents) do
      add :last_compaction_index, :integer, null: false, default: -1
    end

    # 2. Backfill from existing compaction marker rows. COALESCE
    #    absorbs the never-compacted case to the -1 sentinel.
    #    Idempotent on rerun.
    execute("""
    UPDATE agents SET last_compaction_index = COALESCE((
      SELECT MAX(m.message_index) FROM messages m
      WHERE m.agent_id = agents.id AND m.role = 'compaction'
    ), -1)
    """)

    # 3. Drop the index on (agent_id, archived_at).
    drop index(:messages, [:agent_id, :archived_at])

    # 4. Drop the column. After this, `messages` is append-only:
    #    only INSERTs; no UPDATEs on the rows themselves.
    #    (`agents.next_message_index` and `agents.last_compaction_index`
    #    continue to be UPDATEd on the agents row.)
    alter table(:messages) do
      remove :archived_at
    end
  end
end
