# W2 — the messaging core (implementation plan)

Tracking issue: **#31** (`notes/async-messaging-redesign.md` is its mirror).
Prerequisites **W1 (#37)** and **W4 (#32)** are merged; `main` was `cfd19eb` when
this plan was written. Issue **#36** is folded into this workstream.

Four read-only reconnaissance passes mapped the surface this plan is built on.
Their findings are summarised here as `file:line` anchors; the raw reports are
not committed (they were agent output), so where this plan says "recon found",
it means a pass that read the code at `cfd19eb` and nothing has changed since.

## Target model

Every async result is an inbox message; nothing waits.

- `agents-query` delivers a message that marks a **reply obligation** on the
  recipient. It returns immediately; there is no timeout and no wait.
- The obligation is a set of senders. It is cleared mechanically by any
  outbound `agents-send` **that succeeds**, so one reply can discharge several
  queries.
- While a debt is outstanding the agent does not settle to idle: at the
  would-be-idle transition the runtime injects a notice and continues the turn.
  Budget: **1 reminder per debt**, then the runtime gives up and tells the
  requester.
- `agents-spawn` / `agents-batch` results arrive the same way: as inbox
  messages, not as a tool return value.
- `agents-wait` keeps its meaning and becomes meaningful: an idle peer is, by
  construction, a peer with no unpaid debt.

## Decisions (all approved by the user before implementation)

1. **No reply↔query matching.** No ids, no FIFO, no per-query records, no
   requester-side state.
2. **Always async.** No blocking modes anywhere.
3. **Reminder budget 1**, then a runtime give-up.
4. **The reminder names the sender only**, with no quote of the outstanding
   message — agents look it up (#22).
5. **Spawn and batch keep the runtime's name-keyed result forward.**
6. **`clone_context` stays as-is**, not optimised for.
7. The query is delivered as an **agent** message with `from:` set, so the
   target sees `[Message from agent "X"]`.
8. **A queued human message is delivered with no sender framing** (landed in
   W1).
9. **The give-up is an honest runtime notice, not an impersonation.** It must
   not read as `[Message from agent "X"]` — X did not say it. A distinct entry
   kind (`:notice`) carries it.
10. **The reminder budget is per-debt**, stored as `%{sender => reminders_sent}`
    rather than a bare set, and the counter resets when the debt set empties —
    so a query that arrives after a give-up still gets its one reminder.
11. **A failed `agents-send` does not discharge the debt.** Only a successful
    delivery clears it.
12. **Blocked / stopped / archived gives up immediately**; a BEAM restart
    accepts the loss (the state is in-process and ephemeral) but logs a warning.
13. **`timeout` is deleted** from `agents-query` and `agents-spawn` (nothing
    waits). `agents-batch` keeps its `timeout`, which becomes the coordinator's
    per-item deadline.
14. **`max_result_tokens` is deleted** from `agents-query` and `agents-spawn`:
    the answer is an inbox message now, bounded by the inbox's offload cap, and
    a schema entry that no longer applies is worse than none.
15. **`owed_replies` reaches the browser** (status payload, `chat:status` reply,
    init payload) and is rendered. State the user cannot see is state we are
    hiding.
16. **#36 backgrounds automatically** on any message arriving during
    `:executing_tools`. It is per-*batch*: one worker produces one result
    message, so a mixed fast/slow batch backgrounds both.
17. **#36: a Stop kills backgrounded workers.** "Do not lose the tool call" is a
    promise about *messages*, not about surviving a stop.
18. **#36: the synthetic result is not an error.** `is_error: true` is retry bait
    (the model would re-run a `file-write`); it needs its own wording, not the
    existing repair text.
19. **W5's dumps need a `.gitignore` rule PR A must add**: add
    `notes/usage-runs/` to `.gitignore`. The new `notes/*.log` rule does not
    cover the `*.jsonl` these write — see the note at the end.

## Shape of the work

**Two PRs**, not four:

- **PR A — W2 core**, including W5's observation kit. The query path, the debt,
  the gate, the give-up, spawn/batch async, the deletions, the tool text, the
  UI, and the instrumentation. These are one coherent semantics change and
  splitting them would mean writing the tool text and the instrumentation twice.
  *If the diff turns out to be unreviewable, the natural split point is between
  the query path (§1) and the spawn/batch path (§2).*
- **PR B — #36**, delivering a message through a blocking tool call. It builds
  on PR A's inbox machinery and changes the `:executing_tools` disposition that
  several tests pin, so it goes second.

---

# PR A — W2 core

## 1. The query path: a reply is an owed message

### 1.1 `:query` entry kind and the delivery path

Files: `lib/nest/agents/agent/inbox.ex`, `lib/nest/agents/agent.ex`,
`lib/nest/agents/agents.ex`, `lib/nest/tools/query_agent.ex`.

- Widen `@type kind` (`inbox.ex:100`) to `:agent | :user | :query | :notice`.
- `handle_delivery/3` (`inbox.ex:126-166`) hard-codes `:agent` in both the busy
  and the idle arms; give it the kind (or add a sibling entry point).
- `enqueue_internal/4`'s guard (`inbox.ex:197`) must admit the new kinds.
- `Agent.deliver_message/3` (`agent.ex:409`) and `Agents.send_message/4`
  (`agents.ex:291`) carry the kind through.
- `Inbox.combine/1` already renders every non-`:user` entry through
  `agent_label/1`, which gives decision 7 for free — but a `:notice` must **not**
  be rendered as a peer's words (decision 9).

**Acceptance:** a `:query` to an idle agent is delivered and sets a debt; to a
busy agent it queues with `kind: "query"`; to a broken agent it returns
`{:error, {:status, s}}`; `:inbox_full` still refuses a peer.
**Verify:** `inbox_test.exs` per disposition; a channel test for the wire shape;
`Inbox.batch/1`'s totality (already pinned) still holds for the new kinds.

### 1.2 `owed_replies` on the machine

Files: `lib/nest/agents/agent/machine.ex`, `test/.../machine_structure_test.exs`.

Add `owed_replies: %{String.t() => non_neg_integer()}` (decision 10). The machine
is the right home: it is **not** rebuilt by compaction (`do_commit/2` resets
`crossed_thresholds`, `context_projection`, `read_files` and empties
`chat_state.messages`, but never touches `state.live.machine`), it is never
serialised to the LLM, and `validate!/1` asserts only phase/worker invariants,
so a plain new field needs no validator change.

**Acceptance:** the debt survives a compaction; it is invisible to the model.
**Verify:** a machine test that compacts with a debt outstanding and asserts it
persists; `machine_structure_test.exs`'s field pin updated deliberately.

### 1.3 Set the debt at delivery, not at enqueue

Files: `lib/nest/agents/agent/machine/transitions.ex` (`start_chat/3`'s `:fits`
branch, ~`:456`), `lib/nest/agents/agent/machine/boundary.ex` if the batch needs
to be visible there.

The `:fits` branch already has the peeked batch in hand, so it can set a debt
for every `%{kind: :query, from: from}` in it.

**Acceptance:** a query queued behind a busy agent that is never delivered (the
agent blocks or restarts first) must **not** create a debt.
**Verify:** a machine test: drain parks on `:needs_compaction` → no debt; drain
fits → debt.

### 1.4 Clear the debt on a successful outbound send

Files: `lib/nest/agents/agent/tool_loop.ex` (`run_send_agent/2` ~`:418-451`),
`lib/nest/agents/agent/callbacks.ex`, `lib/nest/agents/agent/handlers.ex`,
`lib/nest/agents/agent/machine/transitions.ex`.

The tool worker runs in a `Task.Supervisor` process and today tells the *target*
nothing about the sender. On a successful `Nest.Agents.send_message/4` it must
cast its own agent a debt-clear for that sender. A new tag must be routed
(`Handlers.route_for/1` falls through to `:no_match`, which silently drops) and
the machine must accept the event in every non-blocked phase.

**Ordering requirement (load-bearing):** the clear must be processed **before**
the next idle evaluation, so the gate never reminds for a reply already in
flight. The cast is sent during tool execution, i.e. before
`{:tool_results, ref, results}`, so mailbox order gives this — but it must be
pinned by a test, not assumed.

**Acceptance:** one reply clears several debts for the same sender; a failed
send leaves the debt (decision 11).
**Verify:** "two queries, one reply clears both"; "the reminder never fires for a
reply sent in the same response"; "a failed send leaves the debt".

### 1.5 The idle gate

Files: `lib/nest/agents/agent/machine/response.ex` (`finalize_or_defer/4`,
`:156-167`).

Model it exactly on the `[:truncated, :silent]` branch (`response.ex:125-141`):

```
{:ok, base ++ [{:append, assistant_msg}, {:append, reminder}, :iterate], machine}
```
with the phase entered as `:generating`/`:http` — **not** `:idle`. Entering
`:idle` would manufacture the transient idle that #15 exists to prevent, and
`agents-wait` reads the status.

- The reminder is a synthetic user message (`ContextReminder.build_user_notice/2`,
  `context_reminder.ex:150-159`), which carries no sender label and no `[mode:]`
  prefix.
- Copy `nudge_or_finalize/2`'s fit guard (`response.ex:427-435`): if the notice
  does not fit the remaining budget, do not inject.
- **The budget must not be a transcript scan.** `count_prior/2`
  (`response.ex:437-443`) counts nudge texts in `ctx.messages`, and a compaction
  empties `chat_state.messages` — a transcript-scan budget would reset across a
  compaction and remind forever.

**Acceptance:** a debtor never reports `idle`; exactly one reminder per debt;
the notice names the sender(s) and quotes nothing.
**Verify:** a settle-loop test asserting the status sequence never contains
`idle` while the debt stands; a budget-exhaustion test; a fit-guard test.

### 1.6 The idle-site audit and the give-up

Files: `lib/nest/agents/agent/machine/compaction.ex`,
`lib/nest/agents/agent/machine/transitions.ex`,
`lib/nest/agents/agent/turn.ex`, `lib/nest/agents/agent/turn/executor.ex`,
`lib/nest/agents/agent/machine.ex`.

Recon enumerated **16** sites that enter `:idle`. Classify each as:

- **re-prompt** — only `response.ex:158` (the normal settle, §1.5).
- **give-up** — `:loop_ack` (`transitions.ex:94`), `{:unblocked}`
  (`:133`), `:stop_timer` (`:165`), `{:llm_error, …}` (`:300`), `worker_down`
  (`:617`), `recover_interrupted_tool :none` (`:628`), `fail_turn` (`:644`),
  `reserve_exhausted`'s held-user arm (`compaction.ex:112`) and nothing-arm
  (`:128`), `resume_with_pending` (`:213`, `:225`), `resume_notice` (`:233`),
  `quarantine!` (`turn.ex:83`), `:empty_assistant` (`response.ex:120`).
- **out of scope** — `:workspace_notice` (`transitions.ex:274`, already idle).

**The sharpest hole (the 17th site):** `resume`'s
`{:assistant_response, …}` arm (`compaction.ex:189`) finalises a reply that did
not fit, with
`{:finalize, :clean}` — a debt set before that compaction is silently dropped
unless this site is handled.

Add **one** executor action that sends the give-up via `Nest.Agents.send_message/4`
and clears the debt, so the clear rule stays uniform. Register it in
`Machine.@actions`, the executor, and `guard_test.exs` (which pins action↔clause
coverage).

**A refused give-up must not be silent.** `handle_delivery/3` can refuse with
`{:error, {:status, s}}` (broken requester) or `{:error, :inbox_full}`, and
`Agents.send_message/4` can return `:not_found`. Mirror
`AsyncWaiter.delivery_failed/4` (`async_waiter.ex:226-238`): `Logger.warning` +
`Broadcasts.notification/3`.

**Also:** `:stop_timer`'s action list ends with `{:drain_inbox}`
(`transitions.ex:166-167`); a queued `:query` drained *after* the give-up would
set a fresh debt on a turn about to idle. Fix the ordering or handle it.

**Acceptance:** every `:idle` entry either clears the debt or provably carries
none; a refused give-up is logged and notified.
**Verify:** one test per class; a data-driven table test if the sites allow it.

### 1.7 Delete `PeerQuery` and the query half of `AsyncWaiter`

Files: delete `lib/nest/agents/agent/peer_query.ex` (175 lines); delete
`AsyncWaiter.query_wait/6` and its plumbing; delete
`SubAgentResults.query_success/3` + `query_failure/2`;
`lib/nest/agents/agent/tool_loop.ex:379-412` becomes deliver-and-confirm.

`PeerQuery`'s two callers are `tool_loop.ex:387` (blocking) and
`async_waiter.ex:172` (async). It has no state, no process and no struct — it
blocks in the caller's process, correlating by positional index.

**Acceptance:** no blocking path for `agents-query`; the confirmation tells the
model the answer will arrive as a message.
**Verify:** delete `tool_loop_query_error_test.exs` (its subject is gone);
rewrite the query half of `tool_loop_async_test.exs`; `guard_test.exs` green.

### 1.8 Tool text and UI for the query path

Files: `lib/nest/tools/query_agent.ex`, `lib/nest/tools.ex` (`agents-send`'s
"use `agents-query` when you need the response now" is false under the new
model), `priv/repo/seeds.exs:226-235` (Team Lead step 4: the `async: true` advice
and "when you need a result before continuing"), `lib/nest/agents/agent/broadcasts.ex`
(`status_payload/1`), `lib/nest/agents/agent/introspection_handler.ex`,
`lib/nest_web/channels/agent_channel.ex` (`chat:status` reply + init payload),
`assets/js/channels/agent.js`, `assets/js/components/InboxPanel.jsx`.

- Remove `async` and `timeout` from `agents-query`'s schema (decisions 13, 14).
- Add `owedReplies` to the status payload, the `chat:status` reply and the init
  payload, forward it in `statusExtras`, and render it in `InboxPanel` as a
  section with an explicit *none* state (a missing value must never render as
  nothing).
- `InboxPanel.senderLabel/2` gets a `:query` branch and a `:notice` branch; the
  unknown-kind fallback stays for genuinely unknown kinds.

**Deployment note:** the seeded system prompt is copied into the DB at seed
time, so `seeds.exs` changes need a re-seed to affect existing vocations. Tool
descriptions are rebuilt at compaction and restart, which is consistent with the
prefix-caching rule.

## 2. The spawn/batch path: results arrive as messages

### 2.1 `Children`'s terminal transition enqueues into the parent's inbox

Files: `lib/nest/agents/agent/machine/children.ex`,
`lib/nest/agents/agent/machine/transitions.ex`
(`resolve_worker_pids/2`, `:667-678`), `lib/nest/agents/agent/turn/executor.ex`
(`{:notify_worker, …}`, `:272-281`), `lib/nest/agents/agent/machine.ex`
(`:notify_worker` in `@actions`), `lib/nest/agents/agent/introspection_handler.ex`.

Replace the terminal hop with an enqueue via `Inbox.enqueue_internal/4`. Delete
`resolve_worker_pids/2` (its whole purpose is finding the worker to notify),
`Children`'s `worker_ref`, the vestigial `{:track_child, …}` payload, and the
`{:notify_worker, name, pid, result}` 4-tuple. `Machine.pending_children/1`
becomes `%{name => true}`.

**Acceptance:** the enqueue happens **in the parent's process**, so a dead worker
pid can no longer lose a result silently — today `send/2` to a dead pid succeeds
and the result vanishes.
**Verify:** `sub_agent_test.exs`, `children_test.exs`,
`machine_structure_test.exs` updated; a new test that a stopped child still
produces exactly one message.

### 2.2 `agents-spawn` always async

Files: `lib/nest/agents/agent/tool_loop.ex` (`run_spawn_blocking/3`,
`run_spawn_async/3`, `await_spawn_result/4`), delete
`lib/nest/agents/agent/async_waiter.ex` entirely (both halves now gone),
`lib/nest/tools/spawn_agent.ex`, `lib/nest/agents/agent/sub_agent_results.ex`,
`lib/nest/agents/agent/wait_budget.ex`.

`AsyncWaiter` has exactly two entry points and no third caller, so deleting both
halves is deleting the module. What goes with it: the `Process.monitor` quiet
exit, the two-phase `{:spawn_agent_go, …}` / `:spawn_agent_abandon` handshake,
the wall-clock deadlines and the `[agents-spawn timed out]` /
`[agents-query timed out]` notes, the `[agents-*-…]` note convention, and the
`async_delivery_failed` notification path (the runtime now enqueues its own
result, which `enqueue_internal/4` never refuses).

`WaitBudget` did not survive: it was deleted outright, and its two constants
(`@default_wait_ms`, `@wait_slice_ms`) were folded into `WaitLoop` as module
attributes, which is where `default_wait_ms/0` and `wait_slice_ms/0` read them.
(That plan expected a correction to `WaitBudget`'s own moduledoc; what happened
instead is that the module went away.)

**Acceptance:** spawn returns a confirmation immediately; the child's turn-final
text arrives as a message.
**Verify:** rewrite `tool_loop_clone_agent_test.exs`, `clone_agent_flow_test.exs`
(the E2E that pairs the spawn `tool_use` with the child's text in the same turn),
`clone_agent_registration_test.exs`. Keep the question the #25 trim deleted a
test for: **what does the parent learn when a child is stopped before it
completes?**

### 2.3 `agents-batch` moves its fan-out into a supervised coordinator

Files: `lib/nest/agents/agent/batch_loop.ex`, `lib/nest/agents/agent/tool_loop.ex`
(`run_agents_batch/2`), `lib/nest/tools.ex` (`batch_agent_function/0`).

The coordinator's final act enqueues the aggregate. `timeout` becomes its
per-item deadline; `on_error: "fail_fast"` becomes "stop the rest and enqueue a
failure message". Note `handle_abandon_child` is a blocking `GenServer.call`
from the batch worker to the parent (`callbacks.ex:162-164`, called from
`batch_loop.ex:323` and `:436`) and must survive in some form.

**Verify:** rewrite the five premise tests in `agents_batch_test.exs` and the
`batch_loop_test.exs` cases that assert a tool result.

### 2.4 Tool text and the delegated-task card

Files: `lib/nest/tools/spawn_agent.ex`, `lib/nest/tools.ex`,
`lib/nest/tools/wait_agents.ex`, `assets/js/components/DelegatedTaskBlock.jsx`.

Drop the `isAsync` distinction — every spawn is async now — and rewrite the note
that says a Stop does not cancel the waiter and a refused result is lost (both
false). `agents-wait`'s result text should say an idle peer is one with no
outstanding replies.

**Verify:** `DelegatedTaskBlock.test.jsx` (22 tests, every `isAsync` one moves),
`tools_test.exs:105-189` (it pins the tool text verbatim).

## 3. W5 — the observation kit

A `mix nest.timeline <space>` writing JSONL plus a human digest to
`notes/usage-runs/<timestamp>/` (PR A must add `notes/usage-runs/` to
`.gitignore`; the `notes/*.log` rule does not cover `*.jsonl`). Records, per
space:

1. Turn transitions: the `(kind, phase)` transition with its triggering event,
   iteration/max, and the message indices appended.
2. LLM calls: correlation to message index and iteration, plus the estimates
   (projected size, budget, remaining) — not persisted anywhere today.
3. Tool calls: name, args, result size, `is_error`, duration, worker.
4. Inbox events: enqueued / queued / delivered / drained / refused, with `from`,
   `kind`, `mode` and the disposition returned to the sender. This makes W1's
   invariant checkable offline.
5. Debt events: set, cleared (and how), reminder injected, give-up sent, give-up
   refused.
6. Status broadcasts verbatim.
7. Every `chat:notification` and `chat:error`, with the `[Source: Module.fn/arity]`
   tag.
8. Compaction: trigger, reserve math, carried entry, loop-breaker count.
9. Per-turn token usage and the context projection.
10. The child graph: spawns, completions, failures, terminations, archives.

The writer must be the same code path the runtime uses for its own events,
otherwise it becomes a second, drifting implementation.

---

# PR B — #36: deliver a message through a blocking tool call

Recon's headline: the tool *worker* is already a separate process, so nothing in
the BEAM blocks — what blocks is the **turn**, which sits in
`:executing_tools` until the batch's single `{:tool_results, ref, results}`
arrives. The proposed bridge is the `pairing_bridge` the codebase already uses,
currently gated out by `MessageAppender.@live_phases` (`message_appender.ex:78`).

### B.1 `Machine.Work.backgrounded`

`%{ref => %{pid, calls}}` on `Work` (`work.ex:23-36`). This is the one piece with
no existing home: without it, `valid_ref?/2` fails when the late
`{:tool_results, …}` arrives and the work is **silently dropped** — the opposite
of the point.

### B.2 The backgrounding transition

A `:executing_tools` + `{:inbox_drain, entries, content}` clause emitting
`[{:append_many, [synthetic_tool, ack, user]}, {:consume_inbox, entries}, :iterate]`
and entering `:generating`.

Legal on the **live** append path without touching `Repair`, because
`Repair.classify_live/2`'s first clause accepts a tool result that answers the
pending ids (`repair.ex:103-104`) — the synthetic result does, and the ack
restores alternation. Staying in `:generating` is mandatory: routing through
`:idle` would manufacture the transient idle #15 rejects.

### B.3 Route the late result

A `{:tool_results, ref, results}` clause that, for a backgrounded ref, renders
each `%ToolResult{}` to text and enqueues it via `Inbox.enqueue_internal/4`, then
drops the entry.

**The real result must re-enter as a message, not as a `tool_result` part.** The
pair is already closed, so a second result for the same id trips
`:no_orphan_tool_results` (`preflight.ex:350-364`) and `Repair`'s `answers_any?`
would find no pending id. There is no transcript shape in which both are
`tool_result` parts.

### B.4 Wording and the invariant comments

New builders in `MessageList` for the backgrounded result content and the ack
(decision 18: not `is_error`, and not `repair_ack/0`'s "was interrupted" — the
call is still running). Do **not** overload the repair builders; the "identical
shapes across repair contexts" invariant is about repair, not about this.

Rewrite the two comments that claim no synthetic tool result is ever fabricated
on the live path (`repair.ex:18-21`, `message_appender.ex:180-184`) — otherwise
the next reader "fixes" #36 away.

### B.5 Stop and deadlines

A Stop must kill backgrounded workers (decision 17) — today the kill targets
`m.work.active_worker` only (`transitions.ex:150-151`), and backgrounded workers
are not linked. Add a deadline plus a notice for a backgrounded call that never
returns, mirroring `AsyncWaiter`'s timeout note.

**Verify:** rewrite `agent_channel_queued_message_test.exs` and
`turn_acceptance_test.exs` 1.1.10 — they currently pin "the message waits for the
batch" — plus new tests for drop-free routing, no transient idle, and a second
message arriving while a different batch runs.

---

## Cross-cutting

- **Livelock.** The gate's only backstop today is `@max_settle_depth 200`
  (`turn.ex:26`), which *raises*. Hence a machine-stored budget and the fit
  guard.
- **`Boundary.drain?/1` competes with the gate's `:iterate`**
  (`transitions.ex:530-545`): a queued message may be delivered instead of a
  fresh request. The reminder still lands; pin the ordering with a test.
- **Coverage.** Deleting two modules changes the denominator; the gate is global
  at 85 with roughly 25 lines of margin. New branches need tests.
- **Every PR** gets an independent review before commit and a full
  `mix precommit` on the frozen tree, as with W1.
- **Test-run logs.** All run output goes to `notes/test-runs/`, which is
  gitignored (`.gitignore:14`) and has no tracked files.
