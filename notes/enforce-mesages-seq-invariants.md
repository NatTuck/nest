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

## 2. Preflight checking

### 2.1 Generalize `Nest.LLM.Preflight`

`Nest.LLM.Preflight` already implements pairing + alternation but is used by
`Nest.LLM.MockClient` only, and its public entry point is mis-named
(`validate_tool_call_pairing/1` also checks alternation). Replace the ad-hoc
`walk/4` with an explicit **rule list**:

```elixir
@rules [
  :known_roles,
  :tool_pairing,
  :no_orphan_tool_results,
  :alternation,
  :no_trailing_orphan
]
```

- Each rule is a function `([Message.t()]) -> [violation]`.
- `validate/1 :: :ok | {:error, [violation]}` runs every rule and unions the
  violations (do not stop at the first).
- Keep `validate_tool_call_pairing/1` as a thin wrapper so `MockClient`'s
  400-parody and `mock_client_preflight_test.exs` keep working.
- A `violation` carries `%{rule: atom, position: non_neg_integer,
  orphan_ids: [...], missing_ids: [...], expected_ids: [...]}`, extending the
  existing shape with `:rule`.

### 2.2 Call site

Call the validator in `Nest.Agents.Agent.ChatTurn.Iteration.spawn_http_worker/2`,
on the exact `messages` list being handed to the worker, **after**
`PreFlight.ensure_passed!/2` and before `start_worker_task/4`. This is the
single choke point for both normal turns and the compactor's turn.

On `{:error, violations}`:

- **Do not** build the request or call the client.
- Surface the failure through the existing Agent error path (a
  `{:chat_crashed, exception, stacktrace}` / `chat:error` broadcast) including
  the rule name and offending ids/positions, and stop the turn.
- The live append-time guard (§3) should make this unreachable; this is the
  last line of defence for restored/legacy state.

### 2.3 Appends are validated too

`MessageAppender.append_one/2` already calls `PreFlight.ensure_passed!/2`.
Extend the append choke point to also satisfy the pairing invariant (see §3)
before the append is accepted.

## 3. Append-time enforcement (prevent)

The single writer is `Nest.Agents.Agent.MessageAppender` (`append_one/2` and
`handle_batch/2`). Every live append flows through it.

Add `Nest.Messages.MessageList.pairing_bridge(messages, incoming) :: nil |
{:tool, Tool.t()}`:

- If the trailing message is an assistant with `Part.ToolUse` parts, compute
  the ids not answered by `incoming`.
- `incoming` is a matching `{:tool, _}` → bridge only the missing ids.
- `incoming` is anything else (notably the next user message) → bridge all
  unpaired ids.
- The bridge is a real `{:tool, _}` message carrying, per missing id, a
  `%Part.ToolResult{is_error: true, content: "Tool call interrupted before
  completion (repaired)."}`.

`MessageAppender` then, before appending a message that would leave an
assistant `tool_use` unpaired:

1. appends and persists the bridge via the canonical path (stamped, broadcast,
   visible to the user — never hidden);
2. appends the requested message.

Return contracts are preserved: `append_one/2` still returns the requested
stamped message; `handle_batch/2` returns every stamped message including the
bridge. `history` appends (compaction markers) are exempt — the invariant is on
the LLM-facing `messages` sequence.

This is what makes the `visual-possum-root` failure impossible on the live path:
the next user message can no longer be appended after an unpaired `tool_use`
without first writing an `is_error` tool result.

## 4. On-load validation (detect)

`Persistence.build_attrs_for_start/2` reconstructs the sequence a restarted
agent will run on. It must:

1. resolve the full recursive sequence via the shared-structure resolver
   (`notes/shared-message-structure.md`);
2. run `Nest.LLM.Preflight.validate/1`;
3. on violation, refuse to start the agent in a sendable state: surface a clear
   error and direct the operator at the offline repair tool (§5). Do **not**
   silently repair in the live path (repairs that insert rows must go through
   §3 or the offline tool).

## 5. Offline repair tool (repair)

A new `mix nest.repair_messages` task. Unlike the live path, it **may rewrite
persisted rows** — that is its purpose.

### 5.1 Options

- `--space <id>` / `--agent <name>` / `--all`
- `--apply` — actually write. Default is **dry-run** (report only).
- `--verbose`

### 5.2 Algorithm (per agent, root-first over the `parent_id` tree)

1. Load the resolved full sequence and the owner partition
   (`own(A)` vs shared prefix).
2. Run the §2 rule list. Print every violation.
3. Build a repair plan:
   - For each assistant `tool_use` missing a paired result at the **owning**
     agent, plan an `is_error: true` `{:tool, _}` insert after it.
   - For stray `tool_result`s with no matching `tool_use`, report them (do not
     invent an assistant).
   - Recompute contiguous `message_index` values for the owning agent's rows.
4. `--apply` runs in a single `Repo.transaction`:
   - Insert the synthetic rows under the owning `agent_id`.
   - Renumber the owning agent's rows with a two-phase pass (temporary large
     offset, then final values) to avoid transient unique-index collisions.
   - Update `agents.next_message_index`; shift `agents.last_compaction_index`
     when an insert lands before the boundary.
5. **Clone renumbering** (the reason `parent_id` matters):
   - An insert into a shared prefix owned by ancestor `P` shifts `P`'s own rows
     and every descendant's fork boundary.
   - For every descendant `C` (recursively, via `parent_id`), shift
     `C.fork_message_index` and all `C`-owned indices at or after the insert
     point by the insertion delta.
   - Fresh children and detached clones (`fork_message_index = NULL`) are
     unaffected.
   - Deterministic: the boundary is the stored `agents.fork_message_index`, not
     a heuristic.
6. Idempotent: re-running on a repaired sequence is a no-op.
7. Dry-run prints the exact inserts and index shifts per agent and exits
   non-zero if any violations were found.

### 5.3 `visual-possum-root`

Root agent, no clones: `mix nest.repair_messages --agent visual-possum-root`
reports the orphan at 866; `--apply` inserts the `is_error` tool result before
index 867. The agent must be restarted afterwards, since its live state still
holds the orphan.

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
2. **Append enforcement** — §3.
3. **Preflight rule list + call site** — §2.
4. **Offline repair tool** — §5.

Phases 2–4 depend on Phase 1 (the repair tool's clone renumbering is only
meaningful once clones share rows).
