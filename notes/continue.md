# Continue: strict shared message structure + sequence invariants

## Mission

Correct the persisted data model so that cloned agents **share** their
ancestors' message rows and never duplicate them, and enforce the
message-sequence invariants so an invalid sequence can neither be created by
the live path nor sent to an LLM. Plus an offline repair tool that may rewrite
persisted sequences.

## Read first (canonical)

- `notes/shared-message-structure.md` — the data model. **Source of truth.**
  Do not edit it to match the code; fix the code.
- `notes/enforce-mesages-seq-invariants.md` — wire invariants, preflight rules,
  append-time enforcement, and the **offline repair tool spec (§5)** /
  **on-load validation spec (§4)**.

If any code comment or other note contradicts the canonical doc, that source is
wrong.

## Status: Phases 1–4 + on-load validation DONE — precommit green

- **Phase 1 — shared structure.** `agents.fork_message_index` (migration
  `20260925171617_add_fork_message_index_to_agents`); `build_insert_base/2`
  also stores `last_compaction_index`. `MessageList.build_clone_fork/4` uses
  Unix-fork semantics (shares the real `agents-spawn` assistant; the child owns
  a `tool_result` for the same id + ack). `Agent.pre_spawn/1` writes the system
  row only for roots/fresh children; clones persist only their own rows.
  `Persistence.Messages.load_full_messages/2` resolves
  `before(full(parent), fork) ++ own` via `parent_id`;
  `build_attrs_for_start/2` uses it and returns `fork_message_index`. Clones
  detach at first compaction (`ResultHandler.handle_success/3` clears the fork
  via `Persistence.update_fork_message_index/3`). Tests:
  `test/nest/agents/agent/shared_message_structure_test.exs`.
- **Phase 2 — append guard.** `MessageList.pairing_bridge/2` returns the repair
  messages (an `is_error` tool result per unpaired id, plus an assistant ack for
  a user incoming). `MessageAppender` routes every live append through
  `append_with_bridge/2`; `append_history_one/2` is exempt. Tests:
  `test/nest/agents/agent/append_pairing_bridge_test.exs`.
- **Phase 3 — preflight + send guard.** `Nest.LLM.Preflight.rules/0` and
  `validate/1` (tagged violations, unknown roles tolerated);
  `validate_tool_call_pairing/1` kept for `MockClient`;
  `format_violations/1`. `Iteration.spawn_http_worker/2` refuses an invalid list
  via `refuse_invalid_sequence/2` (`{:chat_crashed, ...}` + `{:stop, :normal,
  _}`). Tests: `test/nest/llm/preflight_test.exs`,
  `test/nest/agents/agent/chat_turn/send_guard_test.exs`.

All code changes from Phases 1–3 are **uncommitted** on `main` (working tree).

---

## Phase 4: offline repair tool — DONE

Shipped as `mix nest.repair_messages`:
`Mix.Tasks.Nest.RepairMessages` → `Nest.Persistence.MessageRepair` →
`.Planner` (pure) → `.Writer`. It repairs tool pairing **and simple
alternation** violations, is idempotent, and targets whole spaces by
name (`--space <name>`) or everything (`--all`), dry-run by default
(`--apply` to write). See
`notes/enforce-mesages-seq-invariants.md` §5 for the final spec.

The original spec below is kept for context; the implemented CLI uses
`--space <name>` (not `<id>`) and drops the per-agent selector, since
we repair whole spaces.

### Options

`--space <id>` / `--agent <space_id> <name>` / `--all`; `--apply` (default is
**dry-run**); `--verbose`.

### Algorithm (per agent, root-first over the `parent_id` tree)

1. Load the resolved sequence with `Persistence.load_full_messages/2` and the
   owner partition (`own` = `Persistence.load_messages/2`).
2. Run `Nest.LLM.Preflight.validate/1`. Print every violation (rule, position,
   ids).
3. Build a repair plan:
   - For each assistant `tool_use` missing a paired result, plan an
     `is_error: true` `{:tool, _}` insert after it, under the **owning**
     `agent_id` (the agent whose run of rows contains the assistant).
   - Report stray `tool_result`s with no matching `tool_use` (do not invent an
     assistant).
   - Recompute contiguous `message_index` values for the owning agent.
4. `--apply` in a single `Repo.transaction`:
   - insert the synthetic rows;
   - renumber the owning agent's rows with a **two-phase** pass (temporary large
     offset, then final) to avoid transient collisions on the unique index
     `messages_agent_id_message_index_index` (`(agent_id, message_index)`);
   - update `agents.next_message_index`;
   - shift `agents.last_compaction_index` when an insert lands before the
     boundary.

### Clone renumbering (the `parent_id` / `fork_message_index` part)

- An insert into an ancestor-owned prefix shifts the ancestor's rows and every
  descendant's `fork_message_index` and own indices at/after the insert point,
  recursively via `parent_id`.
- Use the stored `agents.fork_message_index` (do **not** derive from min own
  index): a fresh child or detached clone has `fork_message_index = NULL` and is
  unaffected.
- Idempotent: re-running on a repaired sequence is a no-op.

### Code seams to use / add

- `Nest.Persistence.Messages`: `load_messages/2`, `load_full_messages/2`,
  `load_own_messages/1`, `update_next_message_index/3`,
  `update_fork_message_index/3`. `fetch_agent_by_id/1` is currently private — the
  task needs a way to fetch an agent row by id and to list all rows
  (`fetch_all_agents_for_space/1` exists, or add a `list_all_agents/0`).
- `Nest.Agents.PersistedMessage.to_runtime/1` / `from_runtime/2` for building
  the synthetic `{:tool, _}`; `insert_message/3` uses `on_conflict: :nothing`
  (repair must not rely on that for renumbering — use explicit updates).
- Direct `Repo` queries/updates are fine in the task (it runs outside the
  sandbox; it needs `mix ecto`/app started — `Nest.Repo`).

### Tests (Phase 4)

- Fixture mirroring `visual-possum-root`: assistant `tool_use` → user, no
  result. Dry-run reports; `--apply` inserts + renumbers + bumps counters;
  re-run is a no-op.
- Clone fixture: a child with `fork_message_index`; an insert into the parent
  prefix shifts the child's `fork_message_index` and own indices.
- Borrow `test/support/persistence_test_helpers.ex` for spaces/vocations, and
  `Nest.DataCase`.

### Then: repair the real agent

`visual-possum-root` (agent id 1, space 1): index 866 is an assistant
`tool_use:call_00_YeumRvjanX23oPG1S93n4024` (`shell-cmd`, a ~10-min command);
index 867 is the next user message. Look up space 1's name, then run
`mix nest.repair_messages --space <name>` (dry-run) → expect the orphan at 866
(plus the alternation ack needed before the user message); `--apply` inserts the
`is_error` result and the ack; restart the agent. Use the **real** DB, not the
test sandbox.

## On-load validation (spec §4) — DONE

`Persistence.build_attrs_for_start/2` validates the **active sendable
slice** and attaches `sequence_violations` + a `repair_command`;
`Agent.init/1` starts `:needs_repair` (process alive, history
viewable, chat blocked in the GenServer and the channel) and
`Broadcasts.needs_repair/4` drives a UI banner. Recovery is an offline
`mix nest.repair_messages` run plus `Agents.reload_agent/2` (backend:
`Supervisor.restart_agent/2`), which re-validates and returns `:idle`.
Deliberately **not** added: a `list_broken_agents/0` sequence check
(the lobby sidebar only knows about model breakage; sequence issues
surface when the agent loads). See
`notes/enforce-mesages-seq-invariants.md` §4.

## Known residuals / notes

- The full suite is ~9s here, above AGENTS.md's 5s target; pre-existing.
- `mix test --cover` (the precommit coverage stage) is timing-flaky on this
  loaded box. Proven pre-existing: a baseline worktree at `HEAD` also failed the
  same stage, and the failing files pass in isolation. Do not bump test
  timeouts; if it blocks a commit, re-run precommit (it passed cleanly).
- Phase 1's mandatory "no duplicated rows on clone" and restart round-trip tests
  are in `shared_message_structure_test.exs`; keep them green.
- Phases 4 and §4 landed: `notes/enforce-mesages-seq-invariants.md` §4/§5 are
  marked DONE. `mix precommit` is green.

## Open decisions resolved (for context)

1. Fork boundary `F_C = parent.next_message_index`; child answers the shared
   spawn `tool_use` (Unix fork).
2. `fork_message_index` column added.
3. Clone compaction: detach on first compaction.
4. Send-time preflight failure: graceful `chat:error` + stop.
5. Repair tool scope: tool pairing **and simple alternation** (insert one
   opposite-role message between same-type pairs); do not invent an assistant
   to justify a stray `tool_result`.
