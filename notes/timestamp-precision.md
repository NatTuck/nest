# Timestamp precision

**Every application timestamp column is `timestamp(6)` and every schema declares
`:utc_datetime_usec`.** They used to be `timestamp(0)`, and
`Nest.Persistence.now/0` truncated to match. This note records what that was,
why it was done, why it was wrong, and the rule that replaces it.

## What changed

- `Nest.Persistence.now/0` is `DateTime.utc_now()` — no truncation.
- `lib/nest/accounts.ex`'s three invite timestamps (`expires_at` on create, and
  the `used_at` / `revoked_at` stamps on redeem and revoke) are no longer
  truncated either. They were truncating to match the column.
- Seven schemas moved from `:utc_datetime` to `:utc_datetime_usec`:
  `Accounts.Invite` (`expires_at`, `used_at`, `revoked_at`, `inserted_at`,
  `updated_at`), `Accounts.User`, `Agents.PersistedAgent`,
  `Agents.PersistedMessage` (`compaction_occurred_at`, `inserted_at`),
  `Blueprints.Blueprint`, `Spaces.Space`, `Vocations.Vocation`.
- Migration `20261020090000_widen_timestamp_precision` widens the 17 affected
  columns. `schema_migrations` (Ecto's bookkeeping) and
  `agent_name_migrations` (a one-off migration's record) are deliberately left
  at precision 0 — neither is application data.
- Existing rows keep their whole-second values; widening is lossless.

## Reversing it

`down/0` restores `timestamp(0)`, so the migration is structurally reversible —
but it is **data-lossy once this branch has written anything**. Postgres rounds
on narrowing rather than truncating: `'…00:00:00.9'::timestamp(0)` is
`00:00:01`. So a rollback after the application has stored microseconds
silently drops them and can move a timestamp into the next second. Rolling back
is safe only before any post-migration write.

## Why it had been done

Not for the wall-clock-synchronisation discipline. `notes/wallclock-audit.md`
lists wall-clock timestamps explicitly out of its scope — *"wall-clock
timestamps, not synchronization"* — and this change is consistent with that
conclusion: a stored instant is data, and no behaviour here reads one to decide
an ordering.

The actual cause was the column type. Ecto's `:utc_datetime` emits
`timestamp(0)`, so a struct built with `DateTime.utc_now()` (microseconds) did
not equal the row it was written to. `now/0` truncated the struct so the
in-memory value and the persisted value agreed, and every timestamp comparison
in a test could be written as an equality. The truncation was a consequence of
choosing `:utc_datetime` for the columns, then mistaken for a rule.

## Why it was wrong

It degraded persisted data to solve a test problem. Two costs, both real:

1. **The standard representation of an instant was discarded.** An instant with
   sub-second precision is the normal shape; storing a whole second is a
   lossy projection of it, and the loss cannot be recovered.
2. **Sub-second ordering of persisted events became impossible.** Two rows
   written inside one second could not be ordered from `inserted_at` at all —
   and ordering by a persisted timestamp is already load-bearing:
   `Nest.Spaces.list_for_user/1` and `Nest.Accounts.list_user_invites/1` both
   `order_by` one, so their order within a second was arbitrary. The planned
   space feed makes it load-bearing again, ordering a space's notes by time.

A test that needs a coarse timestamp is a test with a requirement, and the
requirement belongs in the test: `DateTime.truncate/2` at the assertion, or an
explicitly pinned value, which is what the test touched here now does.

## The rule

**Never degrade persisted data to make a test deterministic.** If a test needs
coarse timestamps, the test truncates. Recorded in `SMELLS.md`'s Testing
section, where a reader searching for this will look.

## What it bought

- **Ordering that means something.** `list_for_user/1`, `list_user_invites/1`
  and the planned space feed now order by an instant rather than by a whole
  second, with `id` as the tiebreaker for anything that still collides.
- One test the truncation had weakened now asserts what it means:
  `persistence_agents_test.exs`'s "touches updated_at on the existing row" pins
  the original stamp into the past and asserts `:gt`, instead of accepting
  `:eq` because two writes could land in the same second.
- `persistence_test.exs` gains a "timestamp precision" describe that pins both
  halves: `now/0` renders six fractional digits, and a column round-trips an
  arbitrary microsecond (`{123_456, 6}`) unchanged. A third test reads
  `information_schema` and asserts every application timestamp column is at
  precision 6 — the one assertion a `timestamp(0)` column cannot pass, since
  `:utc_datetime_usec` pads *any* loaded value to precision 6.

`accounts_test.exs`'s invite-ordering test already pinned its three values;
only its comment was wrong — it blamed millisecond clustering for what was
second truncation — and the comment is corrected.
