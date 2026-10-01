# Compaction reserve plan

## The core goal (read this first)

**We can always compact.**

At every moment in a live conversation there must be enough context headroom
to run a *single-pass* compaction: a summarization request + the model's
thinking + the summary response. If that headroom is ever unavailable, the
only recovery is the multi-stage, uncached, slow, expensive offline path — and
we must never need it during normal operation.

So we reserve it. Let `L` be the model context limit and

```
C = Reserve.compaction_reserve(L) = max(0.20 * L, 8_192)
```

`C` is the **compaction reserve**. It belongs to compaction and nothing else.

- Ordinary content (system, summary, user messages, tool results, synthetic
  notices/nudges, and **ordinary model replies**) lives entirely in `L - C`.
- The only operation that may spend `C` is a compaction (its request and its
  response).
- If a proposed ordinary message would push the live context past `L - C`, it
  is **deferred** (never persisted into the wrong place, never mutated later)
  and compaction runs first; the message is recorded afterward.
- This is a *structural* guarantee enforced at every append/send choke point,
  not a late check. A late check is only a "this must never happen" tripwire.

The invariant, stated once:

```
for the live LLM-facing context M:   size(M) + C  <=  L
```

If this holds, a compaction request (`M` + a small `[mode: compact]` suffix)
always fits under `L`, and the reserve `C` always funds its response. That is
the whole point: **the conversation can always be compacted.**

Corollaries:

- The reserve is never the reply's budget. Ordinary replies are *deferred*
  when they would cross `L - C`, not accommodated by eating `C`.
- Every compaction marker is bracketed by the summary: the compactor's
  summary assistant message in the archived segment (before) and the
  `summary_user` message in the active segment (after). A missing summary is a
  bug.
- History is immutable once recorded. Deferral happens *before* the first
  persist; we never persist a message and then relocate/re-index it.

## Model

- Live context `M = system + summary + active tail`. `chat_state.messages`
  holds exactly `M`; the archived prefix is derived from
  `last_compaction_index` (`rows where index > last_compaction_index`).
- Compaction is owned by the **Agent**: it decides, budgets, spawns the
  compactor's ChatTurn, and commits the result. The triggering ChatTurn always
  fully exits before compaction runs; a ChatTurn is used only to run the
  compactor's own LLM call.
- `REAL = ConversationSize.size/1` (real token floor + estimator suffix) is the
  size function for all go/no-go decisions. `EST = Estimator` is used only to
  project content that has not been produced yet (future tool outputs, the
  in-flight reply).

## Resolved decisions

| Topic | Decision |
|---|---|
| Deferral trigger | ChatTurn detects (before append), carries via `:needs_compaction`; Agent compacts/commits |
| Ordinary `max_tokens` | `min(model_max_output, round(0.20 * L))` |
| Compactor `max_tokens` | `max(1, L - REAL(input) - estimate_margin)` (whole remaining window; suffix `N` guides the summary) |
| Reserve `C` | keep `max(0.2L, 8192)` |
| Placeholder | minimal textual assistant, persisted (survives a failed compaction; retries need it); the real reply appears only post-summary |
| Tool-call ordering | confirm-then-persist; a failed confirmation defers; never mutate recorded history |
| `Compactor.compact/3` | keep + unify `validate_summary/1`; the live path uses it |
| Summary bracketing | tests assert; the live path logs only (never breaks a live chat) |
| "swap" | rename to **commit** |

## Status

Implemented on this branch (`shell-bg`), `mix precommit` green:

- **Phase 1** — reserve renamed to `Reserve.compaction_reserve/1` with the
  core goal documented in its moduledoc; "swap" renamed to "commit"
  (`archive_active_segment/2`, `commit_compaction/3`,
  `build_active_segment/6`); user-facing overflow message now says
  "compaction reserve"; stale ownership comments
  (`chat_continuation`, `request_compaction_from_task`,
  `{:preflight_request, ...}`) fixed.
- **Phase 2** — `Nest.Tokens.Budget` is the single accounting predicate
  (`size/1`, `content_limit/1`, `fits?/2`, `remaining/2`); `BatchSizer.preflight/2`,
  `BatchSizer.reduce_entries/2`, `Compactor.compute_summary_budget/4`, and
  `CapCalculator.usable_remaining/1` route through `ConversationSize` for the
  live list.
- **Phase 7 (partial)** — `Compactor.validate_summary/1` is the shared summary
  contract; the live `ResultHandler.handle_success/3` validates it and routes
  an empty/think-only summary to the retryable `:compaction_failed` path.

Remaining: **Phase 3** (response deferral + persisted placeholder), **Phase 4**
(synthetic-message accounting), **Phase 5** (send gate), **Phase 6**
(tool-call confirm-then-persist), the rest of **Phase 7** (compactor
`max_tokens`), and **Phase 9** (drift-guard tests).

## Phases

### 1. Naming/semantics (commit + reserve)

- `ResultHandler`: "owns the swap" -> "commits the compaction";
  `archive_pre_swap/2` -> `archive_active_segment/2`;
  `build_post_swap_messages/6` -> `build_active_segment/6`;
  `apply_post_swap/3` -> `commit_compaction/3`. All `pre-swap`/`post-swap`
  comments -> `pre-compaction`/`post-compaction` (state) and
  `archived`/`active` (data).
- `Reserve.response_budget/1` -> `Reserve.compaction_reserve/1`; fix the
  moduledoc and every call-site doc: `pre_flight.ex`, `cap_calculator.ex`,
  `batch_sizer.ex`, `chat_pipeline.ex`, `context_reminder.ex`,
  `notice_injector.ex`, `broadcasts/usage.ex`, `system_prompt.ex`,
  `compaction/overflow.ex`, `planner.ex`, `compactor.ex`.
- UI copy: `TokenUsageChip.jsx` + `Broadcasts.Usage` "working budget (window
  minus the LLM response reserve)" -> "content budget (window minus the
  compaction reserve)".
- Fix stale ownership comments (`chat_pipeline.ex` `{:preflight_request, ...}`,
  `chat_state.ex`/`chat_pipeline.ex` `chat_continuation`,
  `agent_stop_test.exs` `request_compaction_from_task`).

### 2. One accounting primitive

- `Nest.Tokens.Budget`: `size/1` (`ConversationSize`),
  `content_limit(L) = L - C`, `fits?/2` (`size + C <= L`), `remaining/2`.
- Route all gating through it: `BatchSizer.preflight/2`,
  `BatchSizer.reduce_entries/2`, `Compactor.compute_summary_budget/4`,
  `CapCalculator.usable_remaining/1`, planner fit checks. Keep `Estimator`
  only for projections.
- `REAL > EST` tripwire log.

### 3. Response deferral (+ persisted placeholder)

- In `ResponseHandler.handle/3`, before `{:tool_calls_received, ...}`, check
  `Budget.fits?(M + reply)`. Fits -> append. Doesn't fit -> hold the reply;
  persist a minimal textual placeholder assistant (like the compaction request
  suffix; it survives a failed compaction because retries need it); emit
  `{:needs_compaction, self(), {:assistant_response, reply, iter, max}}`; stop.
- Entry plumbing: `ResultHandler.append_entry_tail/2`, `carried_entry_tag/1`,
  `needs_entry`/`mid_turn`/`retry_compaction`.
- The real reply is appended active-side after the summary.
- Ensure `chat_idle` does not clobber a `:compacting` state.
- Covers final text, tool batches (Phase 6), and truncation/silent
  continuations (their nudges go through Phase 4).

### 4. Synthetic-message accounting

- Every synthetic append checks `Budget.fits?`; on failure skip/defer. Sites:
  context notice pairs (`ChatPipeline.maybe_inject_context_pair/1`,
  `NoticeInjector.inject_all/2`), budget reminders, truncation/silent nudges,
  workspace notice pair, synthetic tool results.
- Unify the budget-reminder projection with the batch go/no-go logic.

### 5. Send gate

- `ChatTurn.spawn_http_worker/2`: `Budget.fits?` + `WirePreflight.validate`.
  Ordinary turns must fit; failure is a tripwire -> defer/compact, else
  `:context_overflow`. The compactor turn runs against its own budget.

### 6. Tool-call confirm-then-persist

- Build `assistant_msg`; compute
  `Budget.fits?(M + assistant_msg + projected_results)`.
  - Fits -> persist (`{:tool_calls_received, ...}`), then run the worker.
  - Doesn't fit -> **do not persist**; carry
    `{:tool_call, assistant_msg, iter, max}`, compact, persist post-commit.
- Apply to `handle_regular_tool_calls/3` and `handle_compact_only/3`.
- Removes reliance on `drop_trailing_unpaired_tool_call` for the live path and
  the archived duplicate. Batches remain atomic (all before, all after, none).

### 7. Compactor budget + summary validation

- `compute_summary_budget/4`:
  `n = min(C - system - suffix, L - REAL(current) - suffix)`.
- Compactor request `max_tokens = max(1, L - REAL(input) - estimate_margin)`.
- Keep `Compactor.compact/3`; extract `Compactor.validate_summary/1` from
  `require_summary`/`require_non_empty_summary` and call it from the live
  path (`Lifecycle.finalize_compaction/2` / `ResultHandler.handle_success/3`).
  An empty/whitespace summary routes to `:compaction_failed` (retryable)
  instead of committing an empty summary.
- Marker bracketing: tests assert the summary exists on both sides of every
  marker; the live path logs only.

### 8. Docs / dead code

- Fix `Tokens.Compactor` moduledoc (it still describes the pre-refactor flow).
- Update `notes/no-truncation-or-overflow.md`,
  `notes/context-management-sequence.md`, `notes/context-fixes.md`,
  `notes/extract-compaction-and-resumable-chat-turn.md`.

### 9. Tests / drift guards

- Invariant sweep: `Budget.fits?` holds on every sent and persisted live list
  across user text, tool chains, notices, compaction, continuations, and a
  deferred reply.
- Deferral ordering: `input, placeholder, [mode: compact] suffix, summary
  (assistant) | marker | summary_user, real reply`; marker bracketed;
  placeholder survives a failed compaction.
- Confirm-then-persist: no tool_call persisted when the batch can't fit; no
  recorded history mutated.
- `max_tokens` asserted (ordinary + compactor); empty summary ->
  `:compaction_failed`; `REAL <= EST`.

### 10. Verification

- `mix precommit` with full output under `notes/test-runs/`.
