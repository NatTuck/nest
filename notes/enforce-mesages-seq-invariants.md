# Enforce Message-Sequence Invariants

This is the plan for three related pieces of work:

1. **Message-sequence invariants** — the rules the persisted sequence must always
   satisfy, centred on the immutable shared message structure
   (`notes/shared-message-structure.md`).
2. **Preflight checking** — a named rule list run before *every* LLM request,
   so an invalid request is never sent.
3. **Offline repair tool** — a `mix` task that is allowed to rewrite persisted
   messages (including renumbering all cloned children) to heal sequences that
   the live path already corrupted.

> **Read `notes/shared-message-structure.md` first.** It is the canonical data
> model. If any code comment, note, or doc contradicts it, that other source is
> wrong. Do not "fix" the canonical doc to match the code.

## 0. Why this exists

`visual-possum-root` (agent id 1, space 1) was left in an invalid state after a
container restart interrupted a tool call:

- Index 866 is an assistant with `tool_use:call_00_YeumRvjanX23oPG1S93n4024`
  (`shell-cmd`, a ~10-minute command).
- The restart happened before the tool result was written.
- Index 867 is the next user message. The tool_use at 866 was never paired, so
  the next LLM request was rejected by Anthropic with:

  `messages.866: tool_use ids were found without tool_result blocks immediately
  after: call_00_...`

The live path can leave an assistant `tool_use` unpaired whenever a turn is
interrupted between "assistant tool-call message appended" and "tool result
appended" (crash, BEAM restart, container restart, or a stop during tool
execution). Nothing validated the sequence before sending, and nothing repaired
it on load. This plan closes all three gaps: **prevent**, **detect**, **repair**.

## 1. Message-sequence invariants

### 1.1 Data-structure invariants

- **D1 — One write, one owner.** Every message row is written exactly once and
  owned by exactly one agent (`messages.agent_id`). There are no copies.
- **D2 — Clones share, never copy.** A clone (`agents-spawn` with
  `clone_context: true`) shares its parent's rows `[0 .. F-1]`; it does not
  insert its own copies of them.
- **D3 — Fork boundary.** `F` = the clone's first own `message_index` ("the
  first message associated with the child"). The clone owns `[F ..]`.
- **D4 — Fresh children own from 0.** A fresh child (`clone_context: false`)
  owns its system row at index 0 and shares nothing.
- **D5 — No clone system row.** A clone must never write a system row at
  index 0; index 0 belongs to the root ancestor and is inherited verbatim.
  The clone's identity/depth is carried by the synthetic fork notice it owns.
- **D6 — Recursive resolver.** The full logical sequence of agent `A` is

  ```
  full(A) = (A.parent_id ? before(full(parent(A)), F_A) : []) ++ own(A)
  ```

  where `before(list, k)` keeps rows with `message_index < k`, and `F_A` is
  `A`'s first own index. Resolve recursively up the `parent_id` chain.
- **D7 — Unique index.** `(agent_id, message_index)` is unique. Two agents
  (parent and clone) may hold different rows at the same `message_index`;
  that is expected because rows are scoped by `agent_id`.
- **D8 — Append-only live path.** The live agent only appends. Only the
  offline repair tool (§5) may rewrite/renumber persisted rows.

### 1.2 Wire invariants (Anthropic rules; OpenAI is a superset)

- **W1 — Tool pairing.** Every assistant `Part.ToolUse.id` must be answered by
  a `Part.ToolResult` with the same `tool_call_id` in the *immediately
  following* message.
- **W2 — No orphan results.** A `{:tool, _}` message must immediately follow
  an assistant carrying the matching `tool_use` ids; no extra ids.
- **W3 — Alternation.** No two consecutive `user` or `assistant` wire roles.
  `{:tool, _}` is wire role `user`; `{:system, _}` is ignored for alternation.
- **W4 — Known roles.** Only `:system | :user | :assistant | :tool |
  :compaction` (and `:compaction` only ever lives in `history`, never in the
  LLM-facing `messages` list).
- **W5 — No trailing orphan.** The list must not end with an assistant whose
  `tool_use` is unanswered.

## 2. Preflight checking — DONE

### 2.1 `Nest.LLM.Preflight`

`Nest.LLM.Preflight` now exposes the named rule list via `rules/0`:

```elixir
[:known_roles, :tool_pairing, :no_orphan_tool_results, :alternation, :no_trailing_orphan]
```

- `validate/1 :: :ok | {:error, [violation]}` runs the single-pass walk and
  unions the violations (does not stop at the first). Unknown roles are
  reported by `:known_roles`, not crashed on.
- `validate_tool_call_pairing/1` remains the legacy `kind`-shaped wrapper for
  `MockClient`'s 400-parody.
- `format_violations/1` renders `rule: detail` lines for the `chat:error` path.
- A `violation` carries `%{rule: atom, kind: atom, position: non_neg_integer,
  orphan_ids: [...], missing_ids: [...], expected_ids: [...]}` (plus `:role` for
  `:known_roles`). The walk's four legacy kinds map to rules as: missing/
  mid-list unclosed → `:tool_pairing`, end-of-list unclosed →
  `:no_trailing_orphan`, orphan result → `:no_orphan_tool_results`, alternation
  → `:alternation`.

### 2.2 Call site — implemented

`Nest.Agents.Agent.ChatTurn.Iteration.spawn_http_worker/2` runs
`WirePreflight.validate/1` on the exact `messages` list being handed to the
worker, **after** `PreFlight.ensure_passed!/2` and before
`dispatch_http_worker/2` (which builds the request and spawns the worker).

On `{:error, violations}` `refuse_invalid_sequence/2` sends
`{:chat_crashed, %RuntimeError{}, []}` to the Agent (so `chat_crashed/3`
broadcasts `chat:error` with the rule + ids) and returns `{:stop, :normal,
state}`. The client is never called. The live append-time guard (§3) makes this
unreachable on the live path; it is the last line of defence for restored/legacy
state. Test: `test/nest/agents/agent/chat_turn/send_guard_test.exs`.

### 2.3 Appends are validated too — see §3

`MessageAppender` routes every live append through the pairing repair
(`pairing_bridge/2`), so an append can no longer create an unpaired `tool_use`.

## 3. Append-time enforcement (prevent) — DONE

The single writer is `Nest.Agents.Agent.MessageAppender`. Every live
append flows through it (`append_one/2`, `handle_batch/2`,
`append_in_process/2`); `history` appends (`append_history_one/2`) are exempt.

`Nest.Messages.MessageList.pairing_bridge(messages, incoming) :: [message]`
returns the repair messages to append before `incoming`:

- If the trailing message is an assistant with `Part.ToolUse` parts, compute
  the ids not answered by `incoming`.
- The repair is a real `{:tool, _}` message carrying, per missing id, a
  `%Part.ToolResult{is_error: true, content: "Tool call interrupted before
  completion (repaired)."}`.
- When `incoming` is a user message (wire role `user`), a synthetic assistant
  acknowledgement is returned after the tool result, so the appended user
  message does not create two consecutive `user` wire roles (`tool` is wire
  role `user`). See `notes/valid-turn-ordering.md`.
- `incoming` being a complete matching `{:tool, _}` yields `[]` — a matching
  result is never duplicated.

`MessageAppender` appends and persists the repair messages via the canonical
path (stamped, broadcast, visible — never hidden) before the requested message.

Return contracts are preserved: `append_one/2` still returns the requested
stamped message; `handle_batch/2` returns every stamped message including the
repair messages.

This is what makes the `visual-possum-root` failure impossible on the live
path: the next user message can no longer be appended after an unpaired
`tool_use` without first writing an `is_error` tool result (and the
alternation-preserving ack).

## 4. On-load validation (detect) — DONE

`Persistence.build_attrs_for_start/2` validates the **active
(sendable) slice** — the same list the Phase 3 send guard checks,
i.e. rows with `message_index > last_compaction_index` — via
`Nest.LLM.Preflight.validate/1` (pure, no DB writes). On violation it
attaches `sequence_violations` and a `repair_command`
(`mix nest.repair_messages --space <name>`) to the start attrs; a
healthy sequence gets `[]` / `nil`.

`Agent.init/1` then starts the agent in the `:needs_repair` state
(mirroring the `:model_missing` recovery path): the process stays
alive so history is viewable, `live.status = :needs_repair` blocks
chat in both `Callbacks.chat_or_drop/3` and the agent channel
(`agent_status_needs_repair`), and `Broadcasts.needs_repair/4` pushes
a `chat:status` the UI renders as a repair banner. The operator runs
the offline tool and then reloads the agent (`Agents.reload_agent/2`
→ `Supervisor.restart_agent/2`), which re-validates; a repaired
sequence comes back `:idle`.

Validating the active slice (not the full resolved sequence) avoids
blocking an agent whose orphan sits in history below a compaction
boundary and will never be sent; the offline tool still reports and
repairs the full resolved sequence.

## 5. Offline repair tool (repair) — DONE

Implemented as `mix nest.repair_messages`:
`Mix.Tasks.Nest.RepairMessages` (CLI) → `Nest.Persistence.MessageRepair`
(orchestration + report) → `Nest.Persistence.MessageRepair.Planner`
(pure plan) → `Nest.Persistence.MessageRepair.Writer` (single
transaction). No migration; only `messages.message_index` and
`agents.{next_message_index,fork_message_index,last_compaction_index}`
change.

### 5.1 Options

- `--space <name>` (a whole space, resolved by its globally-unique
  name) / `--all`
- `--apply` — actually write. Default is **dry-run** (report only).
- `--verbose`

Exactly one of `--space`/`--all` is required. Numeric ids are not
accepted; use the space name. Per-agent selection was dropped in
favour of whole-space repair (spaces are closed trees, so there is
no cross-space ancestry). A dry run exits non-zero when violations
are found; `--apply` exits non-zero on residual violations.

### 5.2 Algorithm (whole space, root-first over the `parent_id` tree)

1. Load every agent row and its own rows (bulk, keyed by
   `agent_id`).
2. Resolve each agent's full sequence with the same
   `before(full(parent), F_A) ++ own(A)` resolver the live path
   uses.
3. Walk the resolved sequence with a pairing/alternation state
   machine, root-first:
   - an assistant `tool_use` not answered by its immediate successor
     gets an `is_error: true` `{:tool, _}` inserted after it (or, if
     the successor is a partial tool result, that result is rewritten
     to include the missing ids);
   - two consecutive `user`/`assistant` wire roles get one
     opposite-role message inserted between them (assistant ack after
     an interrupted tool result; a user continuation between two
     assistant turns);
   - stray `tool_result`s with no matching `tool_use` are reported,
     never "fixed" by inventing an assistant.
4. Every synthetic row is owned by the agent being repaired
   (anchored before an existing row of that agent), so an ancestor's
   repair shifts its descendants but never the reverse. Renumber the
   owner's own rows contiguously; shift every clone
   (`fork_message_index > insert index`) fork boundary and own
   indices recursively; shift `last_compaction_index` when an insert
   lands at or before it.
5. Re-validate every resolved sequence and record what remains.
6. Idempotent: a repaired sequence plans no writes. Dry-run prints
   the exact inserts/renumbering per agent with `--verbose`.

### 5.3 Writer

`Writer.apply/1` runs one `Repo.transaction`: phase 1 offsets the
changed agents' rows by a large constant, phase 2 sets final indices
and inserts synthetics (no `on_conflict` reliance), then updates the
agent counters. Any failure rolls the whole run back.

### 5.4 `visual-possum-root`

`mix nest.repair_messages --space <space-name>` reports the orphan
at 866; `--apply` inserts the `is_error` tool result (and the
alternation ack before the following user message). The agent must
be restarted afterwards, since its live state still holds the
orphan.

## 6. Tests

- **Append enforcement** — trailing assistant `tool_use` + append user →
  synthetic `is_error` tool result inserted, persisted, and broadcast; appending
  the matching tool result does not duplicate; batch path atomic.
- **Preflight rules** — one unit test per rule; a deliberately invalid list
  fails with the expected `rule`/positions; a valid shared/clone sequence
  passes.
- **Send guard** — dispatching an invalid list does not call the client and
  surfaces a `chat:error`.
- **Offline tool** — fixture mirroring `visual-possum-root` (assistant
  `tool_use` → user): dry-run reports; `--apply` inserts + renumbers + bumps
  counters; idempotent; a clone fixture asserts the child's fork boundary and
  own indices shift with the parent.
- **Restore** — a persisted orphan refuses to start in a sendable state and
  names the repair tool.

## 7. Code alignment status

**Phase 1 (shared structure) is implemented.** The resolver below is live:

- `agents.fork_message_index` stores the clone's first own index;
  `Agent.pre_spawn/1` persists only the clone's own rows (no system row at 0);
- `Agent.build_child_attrs/5` shares the parent's `history ++ messages`
  including the real `agents-spawn` assistant, whose `tool_use` the child
  answers with its own "you are the clone" result (Unix fork);
- `Persistence.Messages.load_full_messages/2` resolves
  `before(full(parent), F) ++ own(A)` recursively via `parent_id`;
  `build_attrs_for_start/2` uses it;
- a clone detaches (`fork_message_index` cleared) at its first compaction.

The docs remain the contract; any remaining divergence is a code bug.

## 8. Phases

0. **Docs** — `notes/shared-message-structure.md` + the copy-language cleanup.
   **Done.**
1. **Shared structure** — implement D1–D9 in spawn/load/compaction; tests.
   **Done.**
2. **Append enforcement** — §3. **Done.**
3. **Preflight rule list + call site** — §2. **Done.**
4. **Offline repair tool** — §5. **Done** (also fixes simple alternation
   violations). §4 (on-load validation) remains.

Phases 2–4 depend on Phase 1 (the repair tool's clone renumbering is only
meaningful once clones share rows).
