# Continue

This file is the authoritative continuation checklist.

- **Compaction-reserve work** (plan in `notes/compaction-reserve-plan.md`) — DONE.
- **Agent machine refactor** (collapse `ChatTurn` into the Agent) — DONE
  (Steps 1–7 + Plan B). See "Final architecture" below.
- **Post-refactor cleanup** — DONE: seam removal, stale-doc sweep, and the
  final-reply reserve deferral re-wire.

`mix precommit` is green as of the latest checkpoint.

## Core goal (do not lose this)

**We can always compact.** Keep the compaction reserve
`C = Reserve.compaction_reserve(L) = max(0.20*L, 8_192)` free at all
times so a single-pass compaction (request + thinking + summary) fits:

```
for the live LLM-facing context M:   size(M) + C  <=  L
```

Ordinary content — including ordinary replies — lives in `L - C`. Only a
compaction may spend `C`. A proposed ordinary message that would cross
`L - C` is **deferred** (never persisted-then-relocated); compaction runs
first and the message is recorded afterward.

## Invariants

1. **Always compactable** (above).
2. **Indexed = immutable.** A message gets a message index exactly once, at
   commit. Nothing uncommitted ever gets an index or a DB row. No live path
   updates, deletes, or re-indexes a committed row. `chat_state.messages` is
   exactly the persisted active window (`index > last_compaction_index`).
3. **Compaction is not a transaction.** The compaction request — the
   `[mode: compact]` message, plus the assistant bridge the append path
   inserts before it when the wire tail needs one — is **committed before the
   compactor is dispatched**, through `MessageAppender`, exactly like any
   other message. The summary and its marker are committed afterwards, on
   success. A failed compaction therefore leaves the request in the
   transcript, permanently: nothing is removed, because nothing can be.

   This replaced a design that staged the request and the bridge as
   request-only additions and discarded them on failure — *"a failed attempt
   is the ONLY sanctioned sent-but-not-persisted sequence"*. That exception
   was the defect issue #98 reported: the model read a sequence that appeared
   nowhere, so the transcript and the request disagreed about what had
   happened.
4. **Sent => persisted, and alternation holds.** No request-only messages
   anywhere, on any path. The persisted non-system wire sequence never has
   two consecutive `user` roles and every `tool_use` is answered — including
   the compaction request, which is a `user` row separated from whatever
   preceded it by the same `MessageList.pairing_bridge/2` every other append
   uses.
5. **A pending compaction admits nothing else.** Once the request is committed
   and the compaction has not succeeded, the agent may only send or re-send
   that sequence. A retry (`Compaction.retry/1`) re-sends the committed
   messages rather than re-planning — so a retry cannot change the request,
   and cannot append a second one.

   Stated precisely, because the earlier wording of this invariant was false
   and the falseness mattered: `:compacting` is **not a phase**. It is the
   status `Machine.status_for(:generating, kind: :compaction)` — the phase is
   `:generating`, and it accepts plenty of other events (`{:stop, _}`,
   `{:worker_started, _}`, `{:worker_down, _}`, `{:child_*}`, `{:reply_sent, _}`,
   a backgrounded `{:tool_results, …}`). What actually holds the line is:

   * `:compaction_failed` accepts `:retry_compaction`, `{:blocked, _}` and
     `{:unblocked}` (plus child and backgrounded events); everything else is
     refused by its blocked catch-all. Note `:loop_ack` is **not** accepted
     here — it is the exit from `:compaction_loop_detected`, the phase above.
   * The compaction phase **ignores** any other event rather than acting on it —
     **including a refused append**, which is exactly why the request's append
     must be one that cannot be refused (see invariant 6).

   The exits are therefore more than one: `:loop_ack` (the loop breaker's
   acknowledgement), `{:unblocked}` (a model change), and the operator's own
   `/compact`, which deliberately resets the counter because three manual
   requests are a decision, not the automatic loop the breaker guards against.
   The loop breaker bounds an *automatic or retry* chain; it is not a claim
   that compaction is the only thing that can ever happen next.

6. **The compaction request append cannot be refused, so a compaction cannot
   wedge.** The request is a `user` row, and `Repair.classify_live/2` refuses a
   `user` append while any `tool_use` is unanswered — which is the state
   `Response.regular/5` leaves behind whenever a tool batch is about to run.
   Since a refused append is a `{:follow, …}` that halts the action list, the
   machine would sit in the compaction phase with no worker and no exit. So the
   `{:preflight_result, {:refuse, _}}` clause — the refused-batch path, which is
   the near-the-limit case compaction exists for — answers the unanswered tail
   first (`MessageList.unpaired_tail_tool_uses/1` →
   `interrupted_tool_result/1`), and the request append that follows is legal
   and gets a `pairing_bridge/2` like any other. The
   `{:append_result, :invalid, _}` clause for the compaction phase is the
   backstop: a visible turn failure, never a silent hang.

   And the request's own append must **not** reset the loop breaker: it is a
   `user` row, but it is not progress
   (`MessageAppender.progress_message?/1`, `User.compaction_origin/0`).
   Counting it would reset the counter on every attempt and disarm
   `@max_consecutive_compactions`, which is what bounds a compaction that
   keeps failing. The heal row above is excluded the same way
   (`Tool.heal_metadata/0`), since the refused-batch path emits it on every
   attempt too.

   **Scope of the breaker**, because it is narrower than "bounds compaction":
   it bounds the *retry chain* — compact, fail, retry, fail, … — not the commit
   cycle. A compaction that succeeds is genuine progress (the conversation
   shrank), and its commit appends an unmarked assistant and an unmarked user,
   so `loop_count` returns to zero and the next batch refusal is a fresh
   situation rather than a continuation of a loop.


## Sizing basis (resolved)

Anchor on the newest assistant's committed `usage`:

```
reply_value = usage.input_tokens + cache_read_input_tokens
            + cache_creation_input_tokens + output_tokens
size(messages) = reply_value + Estimator.estimate_messages(messages after that reply)
```

- Fall back to a full `Estimator.estimate_messages/1` when no assistant
  carries a usable `usage`.
- Normalize atom (live) and string (restored, `content["usage"]`) keys.
- Missing `output_tokens` -> use `input+cache` and let the estimator cover
  the reply.
- No anchor after a compaction or a cold start -> estimator-only (safe
  direction).
- The message `tokens` field is inert.

## Max tokens (resolved)

`max_tokens` is required on the Anthropic wire; the client substitutes the
model default or 32_000 when the request leaves it nil. Therefore send:

```
compactor: max(1, min(L - Budget.size(input),
                      GenerationDefaults.default_max_tokens(model) || 32_000))
ordinary:  max(1, min(GenerationDefaults.default_max_tokens(model) || 32_000,
                      round(0.20 * L)))
```

Set at dispatch (`Turn.Dispatch`), threaded via `ctx.max_tokens` ->
`RunRequest.max_tokens`. `Budget.size/1` is conservative, so
`input + max_tokens <= L` holds.

## Final architecture

Pure core (`lib/nest/agents/agent/machine*.ex`):

- `Machine` — `status_for/1` is the single observable-status authority;
  `Machine.step/2` (`{:ok, actions, next} | {:ignore, reason, next} |
  :quarantine`), `validate!/1`, `phases/0`, `events/0`, `actions/0`.
- `Machine.Transitions` — the full `do_step/2` table.
- `Machine.Phase` — the only writers of `phase:` (`enter/4`,
  `enter_blocked/2`, `clear_worker/1`).
- `Machine.Compaction` — stage/resume/commit/fail decisions.
- `Machine.Response` + `Machine.Turn` — chat-response branch table and
  `classify_response/1`.
- `Machine.Work` (turn working set) and `Machine.Children` (query children).

Runtime (`lib/nest/agents/agent/turn*.ex`):

- `Turn` — the settle loop (`settle/2`), GenServer dispatch (`handle/2`),
  `drain_inbox/1`, quarantine; every machine event flows through it.
- `Turn.Executor` — the single effect site; runs machine actions in order and
  round-trips impure facts as follow-up events.
- `Turn.Dispatch`, `Turn.Terminal`, `Turn.Commit` — pure request staging,
  terminal recovery, and post-compaction segment builders.
- `Turn.{Messages,BudgetReminder,ContextReminder,HTTPWorker}` — support.
- `MessageAppender` is the single sequence writer (tagged
  `{:ok|:stale|:invalid, ...}`); `Repair.decide/3` is the single repair
  decision; `mix nest.repair_messages` is the offline authority.
- `Inbox` drains through `Turn`; `ChatPipeline` prepares the request.

Deleted: the `ChatTurn` process, `Turn.{APILog,NoticeInjector,Idle,Iteration,
Lifecycle,ResponseHandler}`, `Handlers.TurnHandler`, and
`Compaction.{Trigger,ResultHandler}`.

## Commit checkpoints

`9f29364` (Steps 1–2) → `1f7d591` (3+4a) → `030b92b` (4b) → `911dd58` (5) →
`0d5ed82` (7) → `d53b7b1`, `0e08c42` (cleanup) → `e615965` (Plan B: `step/2`
drives, Executor is the only effect site) → `f759d1c`, `ac9e3ac` →
`3e46a08`, `18820d5`, `3c352e4` (post-review robustness) → `c9dd90b`,
`b40ecd3` (seam removal) → `f69f34e` (route every machine event through Turn).

## Gotchas

- Keep the tree green at every phase boundary; `mix precommit` full output
  under `notes/test-runs/`. Never `git stash`; never revert.
- Preserve `$callers` / Logger metadata when the Agent spawns workers
  (`Task.Supervisor.start_child` does not set `$callers`).
- Watch Agent responsiveness: CPU work the turn does inline (context
  estimation, budget math, notice building) must stay cheap or move to a
  worker, or Agent `GenServer.call` callers hit their timeouts.
- Entry/continuation types live on the `Machine` (`entry`, `resume`,
  `mid_turn_entry`); `{:assistant_response, msg, iter, max}` is the deferred
  final-reply entry carried across a compaction.
