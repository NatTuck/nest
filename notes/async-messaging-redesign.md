# Rework agent messaging around async multi-party messages

Tracking issue for the messaging redesign. **Supersedes #30.** Absorbs #26 and #29
as W1 and #27 as W6. Depends on #22 for the reminder's no-quote behaviour.
Supporting analyses: `notes/review-pr25.md`, `notes/issue-30-design.md`,
`notes/issue-26-27-29-design.md`, `notes/big-space-and-msg-cleanup.md`.

## Why

`agents-query` sends a message through the human chat path and then *infers* the
answer: it waits for the target to be broadcast `idle` and reads the target's
newest assistant message at or after a pre-count snapshot. #15 made this worse in
two ways: a message sent to a busy peer is now **queued** instead of dropped (so
the peer really does answer, but later), and the turn-end path publishes a
**transient idle** (`:idle` is broadcast before the `{:inbox_drain}` follow event
starts the query's own turn), so the waiter accepts the first idle and returns the
peer's *own previous* answer.

The deeper problem is not the race. #15 also made messages arrive at the peer's
**turn boundary** — mid-turn — so a single turn can absorb a human message, an
`agents-send`, and a query before it ends. At that point "the end-of-turn message"
is not attributable to any particular query. No amount of observer-side
correlation (ids, anchored indices, re-reading status) fixes that, because the
*content* is not a reply to anyone in particular. Only an explicit, addressed
reply does.

## Target model

- **Every async result is an inbox message. Nothing waits.**
- `agents-query` delivers a message and marks that the recipient **owes a reply**.
  It returns immediately. Always async; no timeout, no wait.
- The obligation is a **set of senders** the agent owes a reply to. It is cleared
  mechanically by any outbound `agents-send` to that sender — so one reply can
  discharge several queries.
- While a debt is outstanding the agent **does not settle to idle**: at the
  would-be-idle transition it injects a notice and continues. Budget is 1
  reminder; after that the runtime gives up and tells the requester.
- `agents-spawn` / `agents-batch` results arrive the same way: as inbox messages
  from the runtime, not as a tool return value.
- `agents-wait` keeps its current meaning (wait for a peer's idle) and becomes
  meaningful: an idle peer is, by construction, a peer with no unpaid debt.

## Decisions

1. **No reply↔query matching.** No ids, no FIFO, no per-query records, no
   requester-side "awaited replies" state. A single reply may answer several
   queries; the *model* matches replies to questions from its own transcript,
   which is the only place that matching was ever needed.
2. **Always async.** No blocking modes anywhere. The blocking pattern is what
   created this problem: it promised a message the ergonomics of a synchronous
   call, then required us to reconstruct a return value out of turn boundaries.
3. **Reminder budget 1**, then a runtime give-up.
4. **The reminder names the sender only**, with no quote of the outstanding
   message — agents look it up (#22).
5. **Spawn and batch keep the runtime's name-keyed result forward.** A one-shot
   child's turn-final text is safe to treat as its answer, the `Children`
   lifecycle machinery already exists, and a child may not carry the `agents`
   tool group (so it could not reply explicitly). Explicit replies are required
   only for `agents-query`, where turns can be interrupted.
6. **`clone_context` stays as-is**, not optimized for; decide from real usage.
7. The query is delivered as an **agent** message with `from:` set, so the target
   sees `[Message from agent "X"]` instead of `[Message from the user]`.
8. **A queued human message is delivered with no sender framing.** It looks
   exactly like a message the human typed while the agent was idle — its content
   plus the usual `[mode: X]` prefix — so the model never has to reason about
   whether a human message was queued or immediate. The sender stays on the wire
   entry (the panel shows it); only the LLM-facing text changes. Agent entries
   keep their `[Message from agent "X"]` label, which is what disambiguates a
   combined agent batch.

## What gets deleted

| deleted | why |
| --- | --- |
| `Nest.Agents.Agent.PeerQuery` (whole module) | no idle inference, no "newest assistant ≥ pre-count" read |
| issue #30 | superseded: it becomes a module to remove, not a bug to fix |
| `AsyncWaiter`'s query half (deadlines, `[agents-query timed out]`) | nothing waits for a query |
| `AsyncWaiter`'s spawn half | the parent's own `Children` transition enqueues the result |
| `agents-query`'s `timeout` argument, `agents-spawn`'s blocking path, `agents-batch`'s blocking return | no blocking modes |
| `Children`'s `worker_ref` plumbing | no worker to notify |
| "a Stop does not cancel a waiter" and "a refused delivery loses the result" | no waiter, and results are enqueued by the runtime itself |
| the whole reply-correlation design space | not needed once replies are addressed messages |

## Workstreams

### W1 — Inbox correctness (absorbs #26 and #29) — prerequisite

The inbox becomes the result channel, so it must be trustworthy first.

- **Peek-then-consume.** `{:drain_inbox}` computes the content and resolves the
  mode but does **not** clear `state.live.inbox` or rebroadcast; a new
  `{:consume_inbox, entries}` action emitted by `start_chat/3`'s `:fits` branch
  clears and rebroadcasts atomically with the append. Retires `{:restore_inbox}`
  (and its executor clause and `Machine.@actions` entry). Invariant to hold:
  **a queued message is always visible — in the queue or in the transcript,
  never in neither.**
- **A user message is delivered by itself.** `Inbox.combine/1` becomes batch
  selection over the FIFO head: a `kind: :user` head is delivered alone; a run of
  leading `:agent` entries still batches. A user entry delivered alone carries
  **no** `[Message from the user "…"]` framing (decision 8), so a queued human
  message is textually identical to one that arrived while the agent was idle.
  This also removes the documented "the older human message runs under the newer
  one's caps" wart, since each human message now runs in its own mode.
- **#29.** `:reserve_exhausted` must not strand a message: reuse `:loop_ack`'s
  `held_user/1` precedent for the chat-request arm; under peek-then-consume the
  inbox arm keeps the entries queued and enters a blocked phase instead of idling.
- **New: an internal self-enqueue path that bypasses `@max_inbox_size`.** The
  runtime enqueuing its own result must never be refused by its own cap.

*Verification:* machine tests per drain outcome (`:fits` / `:needs_compaction` /
`:cannot_compact` / `:reserve_exhausted`); the frame-sequence integration test
(`count 1` → still `count 1` while `:compacting` → `count 0` after the commit,
asserting on payloads, not frame counts); `Turn.drain_inbox/1` reports `:queued`
when a drain parks; the action↔executor coverage guard test moves with
`:consume_inbox` added and `:restore_inbox` removed.

### W2 — The messaging core

1. **Entry kind and sender identity.** `agents-query` delivers through the
   `Agent.deliver_message/3` path — whose reply is the synchronous disposition
   (`:delivered` / `:queued` / `{:error, reason}`), which also fixes the
   silently-dropped-message case — with `from: <caller name>` and a new entry kind
   (`:query`).
2. **Reply debt.** `owed_replies :: MapSet(sender)` on the machine: set on a
   `:query` delivery; cleared when that agent sends to that sender (a cast from
   the tool worker to its own GenServer, and directly by the executor for
   runtime-sent give-ups); cleared on give-up, stop and archive.
3. **The idle gate.** In `Machine.Response.finalize_or_defer/4`'s fits branch —
   the single funnel for a normal turn end — when the debt is non-empty, inject a
   notice and `:iterate` into a new turn instead of `Phase.enter(…, :idle)`. The
   `[:truncated, :silent]` branch in the same file is the precedent
   (`ContextReminder.build_user_notice/2` + `{:append, …}` + `:iterate`). The
   notice names the sender(s) and tells the agent to reply with `agents-send`.
   Budget 1.
4. **Idle-site audit.** Classify every place that enters `:idle` (~17 across
   `machine/transitions.ex`, `machine/compaction.ex`, `machine/response.ex`) into
   **re-prompt** (the normal settle), **give-up** (failure paths with
   `clear_worker`, `:empty_assistant`, the compaction-loop ack, `:cannot_compact`,
   `:reserve_exhausted`, broken statuses, stop, archive) or **out of scope**
   (compaction resume and notice re-prompt paths, which continue rather than
   settle). A human **stop bypasses the gate** and gives up at runtime.
5. **Give-up.** An executor action that sends the give-up via
   `Nest.Agents.send_message/4` and clears the debt — so the requester learns,
   and the debt-clear rule stays uniform. Fired by the budget and by the terminal
   paths.
6. **Spawn and batch become async.** Drop the blocking paths.
   `Children`'s terminal transition enqueues the completion (or the failure) into
   the parent's own inbox; `Children` no longer needs `worker_ref`. Batch's
   fan-out pacing moves into a supervised coordinator whose final act is to
   enqueue the aggregate.
7. **Tool text and UI.** Rewrite the LLM-facing descriptions for the new contract
   (this is the model's entire mental model for delegation). The inbox panel
   distinguishes entry kinds; the owing agent shows "owes a reply to X"; the
   delegated-task card's async note is rewritten.

*Verification:* "two queries, one reply clears both"; "the reply lands before the
requester's next request while it is mid-turn" (this is #15's boundary delivery
doing the work); "a broken peer gives an immediate delivery error"; "a peer that
never replies gets exactly one reminder and then a give-up message"; "the gate
never fires on a stop"; a machine-guard test that no action lacks an executor
clause after the deletions.

**Test seeds removed by the #25 trim.** The trim deleted two test artifacts
rather than carry them into the redesign, because they cover code W2 deletes.
Recorded here so the replacement tests can be written from them:

- `test/nest/agents/agent/peer_query_test.exs` — the busy-peer baseline
  (Mimic-stubbed `Nest.Agents`): the happy path (subscribe → `chat` →
  `{:chat_status, idle}` → read), the busy-peer mis-resolution, and the
  unchanged `:timeout` / `:no_text` tags. Its subject module goes away; the
  mechanism is documented in `notes/issue-30-design.md`.
- The "an async spawn whose child is stopped" test in
  `tool_loop_async_test.exs` — a real end-to-end drive of the Stop path: spawn
  with `async: true` and a short `timeout`, stub `Nest.Agents.chat`, locate the
  waiter with `find_waiter_task/0`, drive the stop with
  `send(coordinator_pid, {:chat_stopped, coordinator_pid})`, assert
  `Machine.running_child_names/1 == []`, then assert exactly one
  `[agents-spawn timed out]` delivery and the waiter's `:normal` `:DOWN` (no
  crash report). **W2's replacement must cover the same question:** what does
  the parent learn when a child is stopped before it completes?

### W3 — `agents-wait` gaps

Add `max_result_tokens` to its schema (it is genuinely missing today, unlike
every sibling tool) and glob/regex name matching. Keep its read-only property: it
reads the space listing rather than `get_info/2` precisely so it never *starts*
the agent it is observing.

### W4 — Per-space `/tmp` (own issue: #32)

Scheduled **immediately after the PR #25 merge and before W1/W2**: it is
mechanical, it needs no redesign, and the messaging work relies on handing long
results between agents as file paths.

`/tmp/nest-<ospid>/space-<space_id>/<agent-name>/…`, with the **space** directory
bind-mounted at `/tmp` so siblings can actually open each other's files. Today
each agent's sandbox binds its own scratch dir, so a path handed to a peer is
unreadable — which breaks "the answer was long, here is the path" between agents.
Cleanup moves off `Agent.terminate/2` to space archival/deletion (the existing
code already carries a hard-won comment about not `rmdir`-ing a shared parent; a
space directory is a bigger shared parent). Mutual readability within a space is
a deliberate decision.

### W5 — Observation kit (the harness)

Real usage is the evidence, so instrument it: a timeline dump (`mix nest.timeline
<space>` or a script) writing to `notes/usage-runs/<timestamp>/` with per-agent
turns, tool calls with args and results, inbox events (enqueued / queued /
delivered / drained), debts set and cleared, reminders injected, and token usage.
Plus UI indicators for debt and pending results, so no state is invisible while
working. Deliberately **not** part of `mix test` (real provider, network, slow).

### W6 — #27 (human-path cap and visible refusal)

After W1, since the consume path changes its shape. Cap the human path at
`@max_inbox_size`, refuse visibly (`Inbox` returns `{:refused, state}`;
`Callbacks` logs and broadcasts a `chat:notification` with `type: "inbox_full"`
and the verbatim content; the client retracts the matching optimistic row and
clears `waitingForResponse`; `NotificationBanner` renders it). Incremental inbox
frames stay a separate optimisation.

## Sequencing

1. Trim and merge the in-flight PR (#17 / #25) — see below.
2. **W4** (per-space `/tmp`, #32) — independent and mechanical, and the messaging
   work depends on handing long results between agents as file paths. Lands
   before the rest.
3. **W1** (inbox correctness) — prerequisite for the messaging core.
4. **W2** (messaging core) — the big one; after this the new semantics are live
   and can be used for real tasks.
5. **W5** alongside W2, so the first real sessions are captured.
6. **W3** independently, whenever.
7. **W6** (#27) after W1.

Each step is its own green PR so increments are usable before the whole thing
lands.

## What happens to the in-flight PR

PR #25 (#17) is green and mergeable, but it *is* the async-modes change that W2
replaces. Trim it to what survives — the `B1` child-link route fix, the
tool/doc text fixes, the `agents-wait` additions and their tests, the stale-note
fixes — and drop the deeper test work inside `PeerQuery`/`AsyncWaiter`, whose code
is slated for deletion. Stop the #30 fix work entirely.

## Deferred to real usage

- Whether one reminder is the right budget (it should be rare, because the query
  is normally delivered mid-turn and answered within that turn).
- Whether `agents-wait` is still needed once replies are messages.
- Whether `clone_context` earns its keep.
- Whether "one reply discharges several queries" happens in practice, or whether
  a second query reliably gets ignored.
- Whether the idle gate feels coercive.
