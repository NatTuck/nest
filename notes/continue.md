# Continue: strict shared message structure + sequence invariants

## Mission

Correct the persisted data model so that cloned agents **share** their
ancestors' message rows and never duplicate them (strict immutable shared
structure), and enforce the message-sequence invariants so an invalid sequence
can neither be created by the live path nor sent to an LLM. Add an offline
repair tool that is allowed to rewrite persisted sequences.

## Read first (canonical)

- `notes/shared-message-structure.md` — the data model. **Source of truth.**
  Do not edit it to match the code; fix the code.
- `notes/enforce-mesages-seq-invariants.md` — the wire invariants, preflight
  rule list, append-time enforcement, and offline repair tool plan.

If any code comment or other note contradicts the canonical doc, that other
source is wrong.

## Fork semantics (corrected)

A clone is a Unix `fork`: it shares the parent's sequence **including the real
trailing `agents-spawn` assistant `tool_use`**, and gets a different return
value at the fork point. The child's first own row is a `tool_result` for the
**same `tool_use` id** ("you are now the delegate"), followed by an assistant
ack. The child does **not** drop or re-synthesize the spawn call. This is why
`F_C = parent.next_message_index` (the child's first own row) works with the
resolver `full(A) = before(full(parent), F_A) ++ own(A)`.

## Phase 1 — DONE

Implemented:

- `agents.fork_message_index` column (migration
  `20260925171617_add_fork_message_index_to_agents`) + `PersistedAgent` field;
  `fork_message_index` stored in `build_insert_base/2`, along with
  `last_compaction_index` (previously dropped on insert, which broke clone
  boundary restore).
- `MessageList.build_clone_fork/4` now answers the shared assistant's
  `tool_use` ids with the child's own results (real path), or synthesizes a
  paired fork when there is no trailing tool call (raw test path).
  `extract_clone_instruction/1` removed.
- `Agent.build_child_attrs/5` shares the parent's `history ++ messages` up to
  the fork point and sets `fork_message_index: parent.next_message_index`.
- `Agent.pre_spawn/1` branches: roots/fresh children write the system row at 0;
  clones persist **only** their own fork rows and no system row.
- `Persistence.Messages.load_full_messages/2` recursively resolves the shared
  prefix via `parent_id`; `build_attrs_for_start/2` uses it and returns
  `fork_message_index`.
- Detach on first compaction: `ResultHandler.handle_success/3` clears
  `fork_message_index` (runtime `TreePosition` + DB) via
  `Persistence.update_fork_message_index/3`.
- Tests: `test/nest/agents/agent/shared_message_structure_test.exs` (clone owns
  only fork rows, full-sequence resolve, restart round-trip, clone-of-clone,
  detach, fresh child). Full suite green (1476 tests).

## Phase 2 — append-time sequence invariants

- `Nest.Messages.MessageList.pairing_bridge(messages, incoming) :: nil |
  {:tool, Tool.t()}`: if the trailing message is an assistant with unpaired
  `Part.ToolUse`, build a `{:tool, _}` carrying an `is_error: true`
  "interrupted" result for every missing id.
- `Nest.Agents.Agent.MessageAppender.append_one/2` and `handle_batch/2`: append
  and persist the bridge via the canonical path before any incoming message that
  would leave a `tool_use` unpaired (notably the next user message). Preserve
  return contracts; `history` appends are exempt.
- Tests: orphan + user append inserts the synthetic result and persists it; a
  matching tool result is not duplicated; batch atomicity.

## Phase 3 — preflight rule list

- Generalize `Nest.LLM.Preflight` (`lib/nest/llm/preflight.ex`) to an explicit
  rule list: `:known_roles`, `:tool_pairing`, `:no_orphan_tool_results`,
  `:alternation`, `:no_trailing_orphan`; `validate/1` runs all rules and returns
  all violations; keep `validate_tool_call_pairing/1` as a wrapper for
  `MockClient`.
- Call `validate/1` in
  `Nest.Agents.Agent.ChatTurn.Iteration.spawn_http_worker/2`
  (`lib/nest/agents/agent/chat_turn/iteration.ex`) on the exact list handed to
  the worker, after `PreFlight.ensure_passed!/2`. On violation: do not call the
  client; surface a `chat:error`/`{:chat_crashed, ...}` with rule + ids and stop
  the turn.
- Tests: one per rule; dispatch of an invalid list does not invoke the client.

## Phase 4 — offline repair tool

- New `mix nest.repair_messages` (`lib/mix/tasks/`), options `--space`,
  `--agent`, `--all`, `--apply` (default dry-run), `--verbose`.
- Per agent, root-first over the `parent_id` tree: load the resolved sequence +
  own partition; run the Phase 3 rules; plan `is_error` tool-result inserts for
  orphaned `tool_use` at the **owning** agent; recompute contiguous
  `message_index`.
- `--apply` in one `Repo.transaction`: insert synthetic rows under the owning
  `agent_id`; two-phase renumber (temporary offset, then final) to avoid
  unique-index collisions; update `agents.next_message_index`; shift
  `agents.last_compaction_index` if an insert precedes the boundary.
- Clone renumbering: an insert into an ancestor-owned prefix shifts that
  ancestor's rows and every descendant's `fork_message_index` and own indices at
  or after the insert point, recursively via `parent_id`. Fresh/detached
  children (`fork_message_index = NULL`) are unaffected. Idempotent.
- Verify against `visual-possum-root` (root, no clones): dry-run reports the
  orphan at 866; `--apply` inserts before 867; restart the agent.

## Phase 5 — docs + verification

- Keep `notes/shared-message-structure.md` and
  `notes/enforce-mesages-seq-invariants.md` in sync.
- `mix precommit` clean (no warnings, no test log prints). Suite runtime is
  currently ~9s, above the 5s target; that is the known residual from earlier
  work, not introduced here.

## Open decisions — resolved

1. Fork boundary: `F_C = parent.next_message_index`; child answers the shared
   spawn `tool_use` (Unix fork). Done.
2. `fork_message_index` column: added. Done.
3. Clone compaction: detach on first compaction. Done.
4. Preflight failure behaviour at send: graceful `chat:error` and stop (Phase 3).
5. Repair tool scope: tool-pairing only (Phase 4).
