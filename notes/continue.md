# Continue: compaction-reserve implementation

Final, agreed plan for the work described in
`notes/compaction-reserve-plan.md`. Branch: `shell-bg`.
`mix precommit` is green as of the last checkpoint. This file is the
authoritative checklist; the plan doc has the longer rationale.

## Status (implemented, `mix precommit` green)

- **Phase 0** — compaction transaction: `Trigger` stages `[bridge?, suffix]` in
  the `{:compaction, staged, carried_entry}` entry; `ResultHandler` persists
  `staged ++ [summary_assistant]`, then the marker, then the new active
  segment, only on success; failure discards. `strip_prior_compaction_attempts`
  and the request-only bridge are gone.
- **Phase 2b** — `ConversationSize` anchors on the newest assistant's `usage`
  (`input+cache+output`); `mark_last_message_tokens/2` deleted.
- **Phase 3** — a final reply that would spend the reserve is deferred as
  `{:assistant_response, msg, iter, max}`; committed once post-summary;
  terminal resume goes idle (no LLM call).
- **Phase 6** — tool-call confirm-then-persist: `post_response_preflight`
  includes the unpersisted assistant message; persist only on fit; defer
  otherwise. Deferred batches are never persisted.
- **Phase 4** — synthetic notices and re-prompt nudges skip when they would
  spend the reserve.
- **Phase 5** — send-gate tripwire in `Iteration.spawn_http_worker/2`
  (compactor exempt).
- **Phase 7b** — `ctx.max_tokens` → `RunRequest.max_tokens`:
  ordinary `min(default, 0.2L)`, compactor `min(L - size, default)`.

Remaining polish: more Phase 9 drift-guard tests (exactly-once across a
compaction is partially covered; a full deferral e2e would help).

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
3. **Compaction is a transaction.** Its request additions (assistant bridge
   when needed + `[mode: compact]` suffix) and its response (summary
   assistant) are staged and persisted once on success; on failure they are
   discarded (with the response log). A failed attempt is the ONLY sanctioned
   sent-but-not-persisted sequence.
4. **Sent => persisted, and alternation holds.** No request-only messages on
   the live path; the persisted non-system wire sequence never has two
   consecutive `user` roles and every `tool_use` is answered.

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
- Delete `mark_last_message_tokens/2`; the message `tokens` field goes inert.

## Max tokens (resolved)

`max_tokens` is required on the Anthropic wire; the client substitutes the
model default or 32_000 when the request leaves it nil. Therefore send:

```
compactor: max(1, min(L - Budget.size(input),
                      GenerationDefaults.default_max_tokens(model) || 32_000))
ordinary:  max(1, min(GenerationDefaults.default_max_tokens(model) || 32_000,
                      round(0.20 * L)))
```

Set at dispatch, threaded via `ctx.max_tokens` -> `RunRequest.max_tokens`.
`Budget.size/1` is conservative, so `input + max_tokens <= L` holds.

## Phases

### Phase 0 — compaction transaction (done first)

Files: `compaction/trigger.ex`, `chat_turn/iteration.ex`,
`chat_turn/response_handler.ex`, `chat_turn/lifecycle.ex`,
`compaction/result_handler.ex`, `chat_turn/state.ex`, `chat_state.ex`.

- `Trigger.spawn_compaction_chat_turn/3`: compute suffix + bridge decision;
  do NOT append/persist/broadcast. Carry `[bridge?, suffix]` in the
  `{:compaction, staged, carried_entry}` entry middle slot. Provisional
  summary index = `next_message_index + length(staged)`; seed
  `streaming_acc` / `active_message_index` from it.
- `Iteration.dispatch_compaction/2`: request = `messages ++ staged`; drop
  `strip_prior_compaction_attempts/1`; keep `drop_trailing_unpaired_tool_call/1`
  as defense. Delete request-only `synthetic_assistant_bridge/0`.
- `ResponseHandler.handle/3`: for the compactor entry, build the summary
  assistant but do NOT emit `{:tool_calls_received, ...}`; stage it (with its
  response log).
- `Lifecycle.finalize_compaction/2`: send
  `{:compaction_done, summary_text, staged, summary_assistant, carried_entry}`.
- `ResultHandler.handle_success/3`: validate first, then insert `staged ++
  [summary_assistant]`, then the marker (tx with boundary bump), then the new
  active segment (`summary_user` + carried tail). Marker token stats over
  `prior ++ staged ++ [summary_assistant]`.
- `handle_error/3`: discard staged + response log; keep `:compaction_failed`
  + carried-entry resume.
- UI: don't broadcast the suffix; stream the summary partial at the
  provisional index; commit to UI+DB on success, discard on failure.

### Phase 2b — reply-value sizing

Files: `tokens/conversation_size.ex`, `handlers/llm_stream_handler.ex`.
- Rewrite `ConversationSize.size/1` per the sizing basis.
- Remove `mark_last_message_tokens/2` and its call in `llm_usage/2` (keep the
  usage-totals merge).

### Phase 3 — reply deferral

Files: `chat_turn/response_handler.ex`, `chat_turn/state.ex`,
`compaction/result_handler.ex`.
- Before append, size the context including the reply; if over `L - C`, stage
  the reply as `{:assistant_response, msg, iter, max}`, emit
  `{:needs_compaction, self(), ...}`, `{:stop, :normal}`. Do not persist (it
  was not part of the compaction request). No placeholder.
- Add the entry kind + `append_entry_tail/2`, `carried_entry_tag/1`, and a
  terminal resume (insert once, set `:idle`, no LLM re-spawn) in
  `spawn_next_chat_turn/2` and `handle_error/3`.

### Phase 6 — tool-call confirm-then-persist

Files: `chat_turn/response_handler.ex`, `chat_turn/iteration.ex`.
- Move `{:tool_calls_received, assistant_msg}` out of `handle/3` into the fits
  branch of `handle_regular_tool_calls/3` and `handle_compact_only/3`; include
  `assistant_msg` in `post_response_preflight/2`.
- On miss, stage `{:tool_call, ...}` / `:compact_tool` unpersisted.
- Remove live reliance on `drop_trailing_unpaired_tool_call/1`.

### Phase 4 — synthetic-message accounting

Files: `chat_pipeline.ex`, `chat_turn/notice_injector.ex`,
`chat_turn/context_reminder.ex` call site, `chat_turn/response_handler.ex`
(nudges), `workspace_handler.ex`, synthetic-result builders.
- `Budget.fits?` guard before every synthetic append; skip/log on miss
  (refuse where wire pairing demands a result).

### Phase 5 — send gate (tripwire)

Files: `chat_turn/iteration.ex`.
- Keep `PreFlight.ensure_passed!` for `:cannot_compact`; on
  `not Budget.fits?(messages, limit)` do NOT send: `Logger.error`, surface
  via `chat:error`, stop the turn. Compactor bypasses.

### Phase 7b — max tokens

Files: `chat_turn/iteration.ex`, `llm/runner.ex`, `llm/run_request.ex`.
- Values per "Max tokens (resolved)"; `build_request/1` spreads
  `max_tokens: ctx.max_tokens`.

### Phase 8/9 — docs + invariant tests

- Reconcile `notes/context-management-sequence.md`, `context-fixes.md`,
  `no-truncation-or-overflow.md`.
- Invariant tests: insert-only (no row update); one row/index per logical
  event across a compaction; deferral ordering `input, suffix(user),
  summary(assistant) | marker | summary_user, real reply` with the marker
  bracketed; reply-value sizing stability across a simulated restore;
  `Budget.fits?` on every sent/persisted live list; `max_tokens` values.

## Verification

- `mix test` (must stay < 5s) and `mix precommit`, full output under
  `notes/test-runs/`. Green checkpoint after each phase. No commits unless
  asked. All phases in one pass.

## Gotchas

- Agent owns compaction; the triggering ChatTurn exits before compaction
  runs, and the old ChatTurn's `DOWN` is ignored because `chat_turn_pid` is
  reassigned by the compactor spawn.
- `Summary` appears twice by design: the archived assistant summary and the
  active `summary_user` (only the latter is in the active window).
- Never `git stash`.
- `Estimator` is only for projections; `ConversationSize`/`Budget` size the
  live list.
