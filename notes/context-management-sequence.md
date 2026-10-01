# Context management sequence — current behavior

> **Status:** this snapshot describes the *pre-fix* behavior. The intended
> model and the fix plan live in `notes/compaction-reserve-plan.md` (core
> goal: **we can always compact** — the compaction reserve `C` is kept free
> and never spent on ordinary content, including ordinary replies, which are
> deferred past a compaction). Parts already implemented on this branch:
> the reserve is renamed to `Nest.Tokens.Reserve.compaction_reserve/1`, the
> `Nest.Tokens.Budget` predicate is the single accounting primitive, and the
> live compactor validates a non-empty summary.

Scope: every place we estimate or count tokens, and every decision
(send / compact / summarize / append / warn) that is derived from such a
count. Branch: `shell-bg`. Line refs are approximate anchors.

Legend for the sizing primitives used below:

- **EST** — `Nest.Tokens.Estimator` (cl100k_base × 1.20 + 10/msg).
- **REAL** — `Nest.Tokens.ConversationSize.size/1` (last real
  `input+cache` token count on a message, plus **EST** over the suffix).
- **PROJ** — `Nest.Agents.Agent.BatchSizer.ProjectedSize.project/2`
  (per-tool *future* output estimate).
- **RESERVE** — `Nest.Tokens.Reserve.response_budget(L)` =
  `max(0.20 × L, 8_192)`.

---

## 0. Sizing primitives

| Primitive | Location | Notes |
|---|---|---|
| `RESERVE` | `reserve.ex:69-72` (`@response_share`/`@response_floor` `:52-53`) | single source of the response budget |
| `EST.raw_count/1` | `estimator.ex:57` | cl100k; falls back to bytes/4 for invalid UTF-8 |
| `EST.estimate/1` | `estimator.ex:101` | `raw_count × 1.20` (ceil) `+ 10` |
| `EST.estimate_messages/1` | `estimator.ex:135` | sum of per-message `estimate/1` |
| `EST.estimate_bytes/1` | `estimator.ex:120` | `bytes/4 × 1.20 + 10` |
| `REAL.size/1` | `conversation_size.ex:75-84` | real floor + EST suffix |
| `PROJ.project/2` | `projected_size.ex` | per-tool planned-output size |
| `CapCalculator.usable_remaining/1` | `cap_calculator.ex:43-48` | `L − REAL(messages) − RESERVE` |
| `CapCalculator.effective_max_result_tokens/2` | `cap_calculator.ex:60-68` | `min(llm_override, floor(usable × 0.80))` |
| 25% safety budget | `system_prompt.ex:53-59,84-87` | `L/4` for the rendered system prompt |

---

## 1. Agent startup (system prompt)

1. Resolve `L` (context limit) eagerly — `Init.initial_context_limit/1`
   (`init.ex:289+`); never `nil` in runtime.
2. Render the system prompt: `SystemPrompt.compose_vocation_config/5`
   (`system_prompt.ex:131-143`). It appends the mode catalog, workspace,
   tool budget, context-limit section, AGENTS.md, and `.nest` section.
3. **Decision:** `SystemPrompt.within_size_budget?/2`
   (`system_prompt.ex:84-87`) must hold (`EST(system) ≤ L/4`); otherwise
   the prompt is considered oversized.
4. Build the initial `{:system, _}` message at index 0
   (`agent.ex:207-239`) and insert agents row + message row.
5. No compaction decision at startup. No reserve arithmetic on the
   initial list beyond the 25% system cap.

---

## 2. Incoming user message (Trigger B: per-`handle_chat` preflight)

`ChatPipeline.handle_chat/3` (`chat_pipeline.ex:41-70`):

1. Store the user message in `pending_user_message` (not yet appended).
2. `handle_preflight/2` (`chat_pipeline.ex:311-322`) →
   `preflight_decision/2` (`chat_pipeline.ex:437-445`) with
   `messages_with_pending/1` (`chat_pipeline.ex:397-402`) =
   `active messages ++ [pending]`.
3. **Decision:** `PreFlight.check_messages/3`
   (`pre_flight.ex:104-119`) using `REAL` and `RESERVE`:
   - `REAL(messages) + RESERVE ≤ L` → `:fits`.
   - else system-alone exceeds → `:cannot_compact` (refuse).
   - else head to summarize empty → `:cannot_compact` (refuse).
   - else `:needs_compaction`.
4. Branch:
   - `:fits` → `append_and_spawn/1` (`chat_pipeline.ex:409-425`).
     - `maybe_inject_context_pair/1` (`chat_pipeline.ex:94-127`) first:
       computes `used = REAL(messages ++ pending)` and compares against
       the **working budget** (`L − RESERVE`) via
       `ContextReminder.highest_unannounced/3`
       (`context_reminder.ex:89-101`, thresholds 25/50/75). If crossed
       and no unpaired `tool_use` is trailing, injects a
       `[notice_user, ack_assistant]` pair.
     - Append the user message (`MessageAppender` — see §7).
     - Spawn the ChatTurn (`ChatTurnSpawner.spawn/4`).
   - `:needs_compaction` → `Trigger.post_turn/1` (`trigger.ex:60-78`);
     the pending user message stays held (see §6).
   - `:cannot_compact` → `refuse_compaction/1` (`chat_pipeline.ex:343-361`):
     set `:context_overflow`, broadcast an `Overflow` error
     (`compaction/overflow.ex:66-98`, uses `EST(system)` + `RESERVE`),
     do not spawn.

---

## 3. ChatTurn iteration (the per-turn loop)

`ChatTurn.safe_iterate` → `iteration_branch/3` (`chat_turn.ex:272-286`):

1. Snapshot the Agent's messages via
   `GenServer.call(agent_pid, :get_messages_with_cancelled)`
   (`chat_turn.ex:241`).
2. Branch:
   - cancelled → finalize.
   - trailing assistant `tool_use` → `execute_pending_tool_calls/2`
     (`chat_turn.ex:317-334`), see §4.
   - compactor entry → `Iteration.dispatch_compaction/2`.
   - otherwise → `Iteration.dispatch_batch/2` (`iteration.ex:93-95`).
3. **Send path:** `Iteration.spawn_http_worker/2`
   (`iteration.ex:242-250`):
   - `PreFlight.ensure_passed!(messages, L)` (`pre_flight.ex:179-189`) —
     **raises only on `:cannot_compact`**; it does *not* check fit.
   - `WirePreflight.validate/1` — sequence/role validity only (not size).
   - `HTTPWorker.run/3` (`http_worker.ex:24-35`) →
     `Runner.request/2` → `Runner.build_request/1` (`runner.ex:60-73`).
4. **Response size control (current):** `RunRequest.max_tokens` is `nil`.
   Clients fall back to `GenerationDefaults.default_max_tokens/1`
   (`generation_defaults.ex:21,40`) or fixed defaults
   (`openai_client.ex:87-88`; `anthropic_client.ex:39,189-191`,
   `@max_tokens_default 32_000`). The reserve is **not** used to bound the
   response.

---

## 4. Tool execution and result sizing (BatchSizer)

### 4a. Pre-execution (per planned tool call)

- `ResponseHandler.handle_regular_tool_calls/3`
  (`response_handler.ex:443-465`) calls
  `post_response_preflight/2` (`response_handler.ex:473-477`) →
  `BatchSizer.preflight/2` (`batch_sizer.ex:144-162`):
  `EST(messages) + Σ PROJ(call) + RESERVE ≤ L`?
  - `:fits` → spawn tool worker.
  - `{:refuse, _}` → send `{:needs_compaction, _, {:tool_call, ...}}` and
    stop (mid-turn compaction).
- `ChatTurn.execute_pending_tool_calls/2` repeats the same
  `BatchSizer.preflight` on resume (`chat_turn.ex:321-333`).

### 4b. Post-execution (cook)

- `ToolLoop.run_batch/2` executes regular tools via
  `BatchSizer.execute/2` and sub-agent tools via
  `run_sub_agent_tool/2`; merges in input order.
- `BatchSizer.cook/2` (`batch_sizer.ex:260-263`) →
  `reduce_entries/2` (`batch_sizer.ex:265-278`):
  - seeds `running = EST(messages) + RESERVE`.
  - per result: `EST(content) + 10` vs the effective cap and the running
    budget; `keep_full?` requires `running + full ≤ L`
    (`batch_sizer.ex:308-309`); otherwise `offload/4` substitutes a
    path-and-head block sized to `L − running − 10`.
  - cap comes from `CapCalculator.usable_remaining` (**REAL**) and
    `effective_max_result_tokens` (`cap_calculator.ex:43-68`).
- Sub-agent results: `ToolLoop.bound_content/3` (`tool_loop.ex:500-510`)
  offloads `agents-query` / `agents-spawn(query)` responses over the same
  cap; `BatchLoop.offload_if_needed/4` (`batch_loop.ex:471-484`) offloads
  `agents-batch` aggregates.
- `context-check` tool (`tools.ex:205-221`) reports
  `EST`/`ConversationSize` and `usable_remaining` (**REAL**).
- Appended tool results go through `MessageAppender` (§7).

> Note the split: preflight/cook seed with **EST**, but the per-result cap
> uses **REAL**.

---

## 5. Post-response notices

On every LLM response, `NoticeInjector.collect_case2_specs/2`
(`notice_injector.ex:50-57`) builds specs:

1. Budget reminder (`state.pending_notice` from
   `ChatTurn.maybe_inject_budget_reminder/1`) when iterations are nearly
   exhausted.
2. Context threshold: `projected_tokens_for_response/2`
   (`notice_injector.ex:170-198`):
   - text/tool-free response → `REAL(messages) + EST(response.text) + 10`.
   - tool-call response → if `BatchSizer.preflight` `:fits`,
     `REAL(messages) + EST(tool args) + RESERVE`; else `L` (force 75%).
   - compared against `L − RESERVE` via `ContextReminder.spec/4`.
3. `inject_all/2` (`notice_injector.ex:64-79`) appends
   `[assistant(attention), user(notice)]` through
   `NoticePairInjector` (persisted via `MessageAppender`), and updates
   `crossed_thresholds` / `context_projection` on the Agent.

**Truncation / silent retries** (`response_handler.ex`):
- `@max_truncation_retries 2` (`:73`): a truncated response appends a
  user nudge and iterates again (`handle_truncated_response/1` `:227-238`),
  so output can accumulate beyond one request's `max_tokens`.
- `@max_empty_retries`: a silent response appends a nudge and retries
  (`handle_silent_response/1` `:207-220`).
- After the response is finalized, `RunResponse.truncated?/1`
  (`run_response.ex:58-59`) uses the provider `stop_reason`
  (`max_tokens`/`length`).

---

## 6. Compaction

### 6a. Triggers

- **Trigger A (post-turn)** — `ChatPipeline.handle_preflight` on
  `:needs_compaction` → `Trigger.post_turn/1` (`trigger.ex:60-78`).
- **Trigger B (mid-turn, tool boundary)** — ChatTurn emits
  `{:needs_compaction, _, continuation}` from
  `execute_pending_tool_calls` (`chat_turn.ex:327-330`) or
  `handle_regular_tool_calls` (`response_handler.ex:456-461`).
- **Trigger C (LLM `context-compact`)** — sole tool call, intercepted in
  the response handler.
- **Workspace-triggered** — `WorkspaceHandler.apply_workspace/2`
  (`workspace_handler.ex:71-86`) preflights the projected notice pair.

### 6b. Budget + spawn

`Trigger.start/2` (`trigger.ex:116-145`):

1. Render the system prompt (`SystemPrompt.compose_vocation_config/5`).
2. **Decision:** `SystemPrompt.within_size_budget?` (25% cap) — else
   `broadcast_oversized`.
3. **Decision:** `Tokens.Compactor.compute_summary_budget/4`
   (`compactor.ex:152-172`), using **EST**:
   `n_headroom = RESERVE − system − suffix`,
   `n_call_fits = L − EST(current_messages) − suffix`,
   `n = min(n_headroom, n_call_fits)`; `0 → :reserve_exhausted`
   (broadcast error, no spawn).
4. Append the `[mode: compact]` suffix (`Agent.__append_message__/2`) and
   spawn a ChatTurn with `{:compaction, _, carried_entry}`.

### 6c. Compactor LLM call

- `Compactor.compact/3` (`compactor.ex:208-224`) → `llm_call_fn.(messages, 0, nil)`:
  the **full** conversation + suffix is sent (guarded by 6b's `n`).
- The compactor turn dispatches with `tools: nil, tool_choice: :none`
  (`iteration.ex:135-147`); response is the summary text.

### 6d. Success / swap

`ResultHandler.handle_success/3` (`result_handler.ex:96-134`):

1. Re-render system prompt + tools (`refresh_vocation_and_tools/1`
   `:144-160`).
2. Build post-swap list: optional rebuilt `{:system, _}` (only when it
   passes the 25% budget, `build_rebuilt_system/3` `:214`), summary
   `{:user, _}`, plus carried entry tail (`build_post_swap_messages/6`
   `:167-207`).
3. Marker stats use **EST** (`Estimator.estimate_messages` `:194-195`).
4. `archive_pre_swap` + `apply_post_swap` persist the swapped list and
   bump `last_compaction_index` / `compaction_count`.
5. Spawn the next chat turn with the carried entry (or resume the held
   user message via `ChatPipeline.resume_with_pending/1`).
6. **No `check_messages` / reserve re-check** is run on the swapped list
   here.

### 6e. Offline / CLI compaction

`Nest.Persistence.AgentCompaction.Planner`:

- `choose_system/1` (`planner.ex:247-262`): `RESERVE − system − prefix`.
- `chunk_budget/3` (`planner.ex:264-269`):
  `summarizer_L − RESERVE − system − summary_budget − instruction`.
- sizes via `size_text/1` → `EST.estimate_bytes/1` (`planner.ex:425`).
- `:reserve_exhausted` surfaces when a budget ≤ 0.

---

## 7. Persistence and the append choke point

`MessageAppender` (`message_appender.ex`):

- `append_stamped/2` (`:191-210`) and `append_marker/2` (`:150-174`):
  1. `PreFlight.ensure_passed!(state.chat_state.messages, L)`
     (`:193`, `:152`) — **only** rejects `:cannot_compact`.
  2. stamp index, update `chat_state.messages`, broadcast, then
     `AgentPersistence.append_message/4` (DB write).
- Every append path (user message, assistant response, tool results,
  notices, compaction suffix, marker) funnels here.
- No append path re-checks the reserve or `L` against the resulting list.

---

## 8. UI / telemetry (the same numbers, displayed)

- `Broadcasts.Usage.context_usage_map/4` (`broadcasts/usage.ex:201-215`):
  `context_input_tokens = REAL(messages)`, `working_budget =
  max(1, L − RESERVE)`, `projected_context_input_tokens` = the last
  threshold projection.
- `context_projection` is set by `ChatPipeline` (`:112`) and
  `NoticeInjector` (`:104-114`); read back by
  `introspection_handler.ex:269` / `broadcasts.ex:331`.

---

## Decision-point summary

| # | Where | Size used | Threshold | Action |
|---|---|---|---|---|
| 1 | startup | `EST(system)` | `L/4` | accept / flag oversized |
| 2 | user turn preflight | `REAL(messages+pending)` | `L − RESERVE` | fits / compact / refuse |
| 3 | context-threshold notice | `REAL(pending)` | 25/50/75% of `L − RESERVE` | inject notice pair |
| 4 | tool-call preflight | `EST(messages) + Σ PROJ` | `L − RESERVE` | execute / compact |
| 5 | tool result cook | `EST` seed + `EST(content)`; cap from `REAL` | effective cap; `L` | keep-full / offload |
| 6 | sub-agent result bound | `EST(response)` | `min(override, 0.8 × usable)` | offload |
| 7 | post-response notice projection | `REAL + EST` | 25/50/75% | inject / mark crossed |
| 8 | compactor budget | `EST(system/current/suffix)` | `RESERVE`, `L` | summary `n` / `:reserve_exhausted` |
| 9 | compaction swap | `EST(marker stats)`, system 25% | `L/4` for system | persist swap |
| 10 | append choke point | none (messages already built) | `:cannot_compact` only | persist / raise |
| 11 | send choke point | none | `:cannot_compact` only | send / raise |

---

## Gaps relative to an absolute "never encroach on `RESERVE`" invariant

1. **Send gate doesn't check fit.** `spawn_http_worker/2` only calls
   `ensure_passed!` (`:cannot_compact`). No `check_messages` over the
   final list.
2. **Messages added after the last fit check.** Context notice pairs
   (`chat_pipeline.ex:94-127`), budget reminders, and workspace notices
   are appended after `preflight_decision`; the compaction swap list is
   never re-checked (§6d.6).
3. **Mixed size functions.** Preflight/cook/compactor use `EST` for the
   current list (`batch_sizer.ex:146,267`, `compactor.ex:164`) while the
   user-turn preflight, thresholds, cap, and UI use `REAL`. Where `REAL >
   EST`, the `EST`-based checks under-count.
4. **Response not bounded by `RESERVE`.** `RunRequest.max_tokens` is
   `nil`; provider defaults (up to 32k) apply. Truncation continuations
   (`@max_truncation_retries 2`) can accumulate several requests' output.
5. **Persist path has no size check** beyond `:cannot_compact`.
6. **TOCTOU.** The ChatTurn gates on a snapshot taken before the send;
   the Agent can, in principle, append between the snapshot and the send.
