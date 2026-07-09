# Unify the Message Sequence

The `messages` table was append-only at insert time but carried a mutable
flag (`archived_at`) that the compaction cycle kept flipping. Restore
worked correctly for the live slice but silently dropped the history
slice. This change replaces the mutable flag with a single,
data-derived boundary on the agent row.

## What it is

- `agents.last_compaction_index` (INTEGER, default `-1`) is the
  exclusive upper bound on the messages slice carried in
  `state.chat_state.messages`. Default `-1` means "no compaction has
  happened; everything, including the system prompt at index 0, is in
  `messages`."
- `state.chat_state.history` and `state.chat_state.messages` keep their
  two-field shape. Invariant:
  `state.chat_state.history ++ state.chat_state.messages == full DB
  sequence in order`.
- `state.chat_state.messages` is exactly
  `WHERE messages.message_index > agent.last_compaction_index`.
- `state.chat_state.history` is the complement
  (`WHERE message_index <= last_compaction_index`). The boundary
  compaction marker lives in `history`.
- The `messages` table becomes truly append-only: only `INSERT`s; no
  `UPDATE`s on the rows themselves. (`agents.next_message_index` and
  `agents.last_compaction_index` continue to be `UPDATE`d on the agents
  row.)

## Why this shape

- **Restore correctness** — `history` rebuilds from the same query
  that builds `messages`. No in-memory pruning, no inconsistency
  window.
- **Consistency** — the agent's in-memory view and the DB rows are
  the same set; the boundary is data, not runtime bookkeeping.
- **Append-only table** — fits the immutability principle that
  `notes/normalize-system-messages.md` argues for at the message
  level.
- **Subagent clone semantics** — `notes/subagents.md` describes child
  agents receiving the parent's full message history. With a single,
  append-only `messages` table, the clone is a straightforward
  `INSERT INTO messages SELECT ... WHERE agent_id = $parent_id` with
  `agent_id` swapped. No special handling for archived vs. active.

## Locked design choices

| # | Choice | Value |
|---|---|---|
| 1 | Boundary column location | `agents.last_compaction_index` (not derived via subquery) |
| 2 | Default value | `-1` (sentinel: never compacted) |
| 3 | Partition predicate | `message_index > agent.last_compaction_index` for `messages`; `<=` for `history` |
| 4 | `messages.archived_at` | DROPPED (column + index) |
| 5 | `record_compaction` write | INSERT marker + UPDATE column, one `Repo.transaction` |
| 6 | First-arg for `record_compaction` | `agent_name` (String) — unchanged |
| 7 | In-memory field shape | `state.chat_state` keeps `:history` and `:messages`; adds `:last_compaction_index` |
| 8 | Backfill | One UPDATE per agent, idempotent, runs on migration |

## Schema migration

`priv/repo/migrations/<ts>_unify_message_sequence.exs`:

1. `ALTER TABLE agents ADD COLUMN last_compaction_index INTEGER NOT NULL DEFAULT -1`.
2. `UPDATE agents SET last_compaction_index = COALESCE((SELECT MAX(m.message_index) FROM messages m WHERE m.agent_id = agents.id AND m.role = 'compaction'), -1)`.
3. `DROP INDEX messages_agent_id_archived_at_index`.
4. `ALTER TABLE messages DROP COLUMN archived_at`.

No data loss. The `archived_at` bit is fully derivable from existing
`role: 'compaction'` marker rows.

## Persistence rewrite

`lib/nest/persistence.ex`:

- Rename `archive_and_compact/4` → `record_compaction/3`. New signature
  `(agent_name, marker_index, archived_count)`. Drops
  `first_index` (was only used to UPDATEs `archived_at`).
- Implementation: pure INSERT on the marker row plus an UPDATE on the
  agents row, both inside `Repo.transaction`. Partial commit would
  produce a wrong partition on restore; the transaction prevents it.
- Rename `load_active_messages/1` → `load_messages/1`. Returns the
  full sequence (active + history + markers) in `message_index` order,
  no filter.
- Add `last_compaction_index/1`. Returns
  `{:ok, integer()}` (where integer can be `-1`) or
  `{:error, :agent_not_found}`.

`lib/nest/agents/agent/persistence.ex`:

- Rename `archive_and_compact/4` → `record_compaction/3` (and the
  internal `do_archive_and_compact/4` →
  `do_record_compaction/3`). Same `persistence_enabled?` gating as
  today.

## Agent state wiring

`lib/nest/agents/agent.ex`:

- `ChatState` adds `last_compaction_index: -1` to its `defstruct`.

`lib/nest/agents/agent/init.ex`:

- Rename `seed_preloaded_messages/2` → `seed_from_db/3`. New arg
  carries the boundary integer. The body partitions the loaded list
  into `(history, messages)` via
  `Enum.split_with/2` at the boundary.
- The persistent system-message defensive prepend stays.

`lib/nest/agents/agent/compaction_lifecycle.ex`:

- In `apply/2`, after the in-memory messages/history swap, also set
  `new_state.chat_state.last_compaction_index = marker_index`. The
  agent-side persistence wrapper fires
  `AgentPersistence.record_compaction/3` (no `first_index` arg).

`lib/nest/agents/agent.ex`:

- Rename defdelegate `__archive_and_compact__/2` →
  `__compaction_completed__/2`.

`lib/nest/agents/agent/handlers/compaction_handler.ex`:

- Rename local helper `archive_and_compact/2` →
  `compaction_completed/2`.

## No changes to readers

Crucially, no production code that *reads*
`state.chat_state.history` or `state.chat_state.messages` needs to
change. The pattern `state.chat_state.history ++ state.chat_state.messages`
(still used in `compaction_lifecycle.ex`, `broadcasts.ex`, etc.) keeps
working verbatim — the partition is just now data-derived.

## Verification

1. `mix ecto.migrate` runs cleanly.
2. `mix ecto.reset && mix run priv/repo/seeds.exs`.
3. `mix precommit` clean.
4. Manual:
   1. Create an agent, chat two rounds, trigger a compaction.
   2. Kill BEAM, restart, `Supervisor.fetch_or_start_agent/1`.
   3. Verify `state.chat_state.history ++ state.chat_state.messages`
      contains the full conversation in order; `CollapsedHistory` UI
      renders the pre-compaction rows (was broken before).

## Out of scope

- **`agents.parent_id` column** (subagents). Same shape is ready for
  the follow-up; the column lives in another PR.
- **`api_logs` rebuild on restore** (TODO.md). Mechanical follow-up;
  the rebuild helper walks
  `state.chat_state.history ++ state.chat_state.messages`.
- **`messages.compaction_archived_count` cleanup.** Still needed for
  `CompactionLifecycle.compute_first_index/2` (history slicing at
  index-time).
