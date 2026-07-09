# TODO

Tasks identified across the compaction debugging and persistence work. Scoped,
ordered, and grouped by topic. Items flagged **[ ]** are pending; **[x]** are
done; **[~]** are scoped but blocked on clarification / follow-up.

---

## Production bug: compactor dropped streamed summary text (FIXED)

- [x] **Fix `Nest.Agents.Agent.Compaction.consume_quietly/2`** so it merges
  accumulator text into `response.text` instead of returning `""` when the
  wire-level `RunResponse.text` is `nil`. The OpenAI/Anthropic streams emit
  `:text` deltas into `acc.text` (an IO-list) but the `:done` event's
  `RunResponse` only carries `stop_reason` + `usage`; text merge normally
  happens via `Runner.normalize_response/2`, which the compactor bypasses.

  Files:
  - `lib/nest/agents/agent/compaction.ex` — added `streamed_text/2` helper;
    `consume_quietly/2` calls it instead of `response.text || ""`.
  - `test/nest/agents/agent/compaction_streamed_text_test.exs` (new) —
    regression tests for OpenAI-style (text: nil), Anthropic-style (text
    populated), in-band error, missing `:done`.

  Verified: test fails 6/8 against pre-fix code; passes 8/8 against fixed
  code. Live probe on `entire-ox` reports `ok=1 text_chars=1932 finish="stop"`
  (was previously misreported as `empty=1 text_chars=0`).

---

## Debug tooling: compaction probe (DONE)

- [x] Build `scripts/compaction_probe.exs` — a self-contained probe that
  replays the compactor's summarization call against the real LLM and
  always writes a full event log to `/tmp`. Self-contained because the
  user said sharing code with `compact_agent_history.exs` isn't a strong
  priority; only `Nest.Scripts.CompactionProbeSupport.summarization_prompt/0`
  is reused (single-source-of-truth for the prompt text).

- [x] Always-on `/tmp` logging. Each invocation writes to
  `/tmp/nest-compaction-probe-{agent}-{pass}-{pid}-{ts}.log`. The log captures
  every canonical event: text deltas, thinking deltas, finish_reason, usage,
  refusal, error, done, plus per-run and aggregate summaries.

- [x] Recovery script keeps `CompactionProbeSupport` (quiet path) — no churn
  for code that already works. `compaction_probe.exs` stops depending on it.

- [x] Tests: `test/nest/scripts/compaction_probe_support_test.exs` +
  `test/support/capture_llm_client.ex` (test-only LLM client capturing the
  RunRequest and returning a canned event stream).

---

## Mid-turn compaction loop on `entire-ox` (OPEN)

Two bugs working together. Reproduced via the probe above (see log:
`/tmp/nest-compaction-probe-entire-ox-head-*.log`).

### Bug 1: `BatchSizer.projected_size` ignores per-tool caps

- [ ] **Fix `Nest.Agents.Agent.BatchSizer.projected_size/2` for `shell_cmd`**
  to consult `CapCalculator.effective_max_result_tokens/2`. Currently the
  catch-all clause falls through to a worst-case 8KB estimate:

  ```elixir
  defp projected_size(%ToolCall{}, _ctx) do
    estimator_overhead(String.duplicate("x", 8192))  # ≈ 2468 tokens
  end
  ```

  Wire name is `shell_cmd` (not `execute_command`); the catch-all fires. For
  3 shell_cmd calls on `entire-ox`:
  - 3 × 2468 = 7404 projection
  - + 8192 reserve
  - + ~10354 messages
  - ≈ 25,950 tokens > 20,000 limit → `:refuse`

  Actual tool outputs (`ls -la` etc.) would be ~200 tokens. Phase 3
  (`handle_over_cap` / cooking) caps correctly; Phase 1 (preflight) lies.

  Fix: replace the catch-all for `shell_cmd` (and possibly other wired
  tools) with a projection that uses
  `min(default_8KB_pessimistic, effective_max_result_tokens(tc, usable))`.

### Bug 2: Loop has no breaker

- [ ] **Refuse second `:needs_compaction` for the same iteration.** When the
  compactor doesn't reduce budget enough, the resumed ChatTurn's
  `execute_pending_tool_calls/2` re-runs preflight and re-sends
  `:needs_compaction` with the same `iteration` — fire another compaction
  cycle. The agent must recognize this and refuse with `:context_overflow`
  (existing terminal state, the channel already rejects `chat:message`
  in that status).

  Files:
  - `lib/nest/agents/agent/handlers/compaction_handler.ex` — branch in
    `needs_compaction/3` on
    `state.chat_state.mid_turn_compaction.iteration == incoming iteration`;
    refuse if match. Same guard in `retry_compaction/1`.
  - `test/nest/agents/agent_chat_turn_iteration_test.exs` — new regression
    test: same-iteration double `:needs_compaction` → overflow status +
    `chat:error`.

### Compactions observed in production log

For reference, the loop signature in the user's log:
- Cycle 1: 6 messages → 5, archive `[67..67]` (1 row), insert at 68.
- Cycle 2 (5 s later): 5 → 5, archive `[74..74]` (1 row), insert at 75.
- Cycle 3 (5 s later): same shape, archive `[81..81]`, insert at 82.

Compactor reduces `messages` by 1 per cycle; tool projections unchanged.
Same iteration, same tool calls. `:refuse`. Loop.

---

## api_log persistence (FIXED)

UI loses "API Logs" expander after BEAM restart. Per-message `api_logs`
on `state.chat_state.messages[i]` is in-memory only; never persisted.
`PersistedMessage.to_runtime/1` always returns `api_logs: []` for every
role. After restart, every message has empty api_logs.

### Bug: O(n²) storage if persisting naïvely

If we persist every request api_log (each carries `messages[0..idx]` plus
tools/tool_choice/model), at 1M context that's ~200MB per cycle.
Compaction cycles can produce tens of cycles per session → GBs. The
original authors deferred this for that reason.

### Asymmetry that makes selective persistence possible

- **Assistant message**: `api_logs = [response]` only. A few KB (the
  LLM's output: text + tool_calls + finish_reason + usage). Persist.
- **User message**: `api_logs = [request]` only. Tens to hundreds of KB
  (every prior message + tools + tool_choice + model). Don't persist;
  rebuild on restore.
- **Tool result message**: same shape as user message. Don't persist;
  rebuild on restore.
- **System message**: no api_logs in practice. Persist `[]` for forward
  compatibility.

### Plan (all shipped)

- [x] **`PersistedMessage.serialize_content/2`** — `:assistant` and
  `:system` rows now ALWAYS carry the `apiLogs` key (self-documenting
  even when empty). `:user` and `:tool` rows DON'T carry `apiLogs` in
  their content (the O(n²) cost would compound across compactions).

- [x] **`PersistedMessage.to_runtime/1`** — `:assistant`/`:system`
  read `content["apiLogs"]` back and re-atomize keys + the `type`
  value (`:request`/`:response`) so post-restore runtime code's
  `log.type == :request` works. Default `[]` for old rows that pre-date
  the change.

- [x] **`Nest.Agents.Agent.Restore` module** (`lib/nest/agents/agent/restore.ex`,
  new) — three pure functions:
  - `rebuild_request_api_logs/4` walks `Enum.take(messages, idx + 1)`,
    builds `%RunRequest{tool_choice: :auto, stream: true,
    metadata: %{}}` (matches live defaults documented in a code
    comment), calls
    `client_config.client.format_request_payload(request, [])` (no
    `opts` — wire format only), wraps as wire-shape log with id
    `format_sequence_id(idx, 0)` (matches `Broadcasts.next_api_log_id/2`).
  - `initial_sequences_for/1` returns `%{idx => 1}` for every
    `:user`/`:tool` index in the preloaded sequence.
  - `attach_rebuilt_api_logs/3` is the orchestrator called from
    `Agent.init/1` — populates `:user`/`:tool` `.api_logs`, merges
    `initial_sequences_for/1` into
    `state.chat_state.api_log_sequences`. Idempotent (skips rebuild if
    the row already has non-empty `api_logs`).

- [x] **`Restore.initial_sequences_for/1`** — done in the Restore
  module above. `%{idx => 1}` for `:user`/`:tool`.

- [x] **Wire into `Agent.init/1`** — calls `Init.attach_rebuilt_api_logs/3`
  AFTER `Init.seed_from_db/3`, with the FULL preloaded sequence (so
  user/tool messages in either `state.chat_state.history` or
  `state.chat_state.messages` get the rebuilt request log).

- [x] **Tests**:
  - `test/nest/agents/persisted_message_test.exs` (new, 7 tests).
  - `test/nest/agents/agent/restore_test.exs` (new, 14 tests).
  - `test/nest/persistence_agents_test.exs` — 2 new tests covering
    `:initial_api_log_sequences` and assistant `api_logs` round-trip
    via `build_attrs_for_start/1`.

### Critical context

- **JS doesn't read `log.id`** — `ApiLogsBlock.jsx:66` uses
  `key={log.timestamp}` only. The rebuilt id (`"003.000"` via
  `:io_lib.format("~3..0B.~3..0B", ...)`) just needs to keep the
  wire shape consistent.
- **`Message.format_api_logs/1`** kept the original
  `to_string(log[:type])` for the wire format. The atom rehydration
  for runtime use happens at the DB-read step via
  `api_logs_from/1`'s `rehydrate_value(:type, "request")` →
  `:request`.
- **`Init.attach_rebuilt_api_logs/3` is idempotent**: a row that
  already has non-empty `api_logs` is skipped. Today the rebuild is
  the only writer for `:user`/`:tool`, but this prevents
  double-rebuild if a future flag is added.

### Verification

`mix precommit` clean. 855 tests, 0 failures. `mix ecto.migrate`
clean. `archive_at` schema cleanup (the prior task) and api_log
persistence (this task) shipped together unblocked the UI rendering.

### Open clarifications (blocked)

- [~] **`archived_at` schema cleanup.** The user pointed out this should
  have been replaced by `last_compaction_index` on the Agent. All message
  rows live in one table; agent has a counter marking what's "history" vs
  "active". Not blocking the api_log fix (the messages slice is the same
  regardless of schema), but worth capturing as follow-up.

- [~] **History rebuild.** `state.chat_state.history` is in-memory only.
  After restart, it's `[]`. The `messages` table HAS the archived rows
  (or will, once we switch to the counter scheme). History rebuild
  walks archived rows + compaction markers, groups by compaction, builds
  slices. Same shape as the api_log rebuild. Captured as follow-up; not
  blocking this PR.

- [~] **Iteration-cap edge case.** `handle_overflow_tool_calls/2`
  appends a synthetic error tool result and forces finalize with
  `tools: nil, tool_choice: :none`. Rebuild for the synthetic tool
  message would produce a request that doesn't match (live path switched
  tools). Recommend: rebuild handles gracefully, don't crash; don't pin
  exact byte-equivalence for this edge case. Confirm.

- [~] **Tool results use same rebuild path as user.** Per the user's
  confirmation: yes — continuation LLM calls have the same request
  payload shape as user turns. Treat identically to `:user` in
  `rebuild_request_api_logs/4`. Confirm in implementation.

---

## Open questions carried from the conversation

- [~] **Rebuild helper location** — new `lib/nest/agents/agent/restore.ex`,
  or inside `init.ex`? Recommend new file; matches the
  `compaction_lifecycle.ex` pattern. Confirm.
- [~] **`stream: true` and `metadata: %{}` on rebuilt `RunRequest`** —
  these mirror live defaults but aren't persisted. Document as a comment
  in the rebuild function so future readers don't add them to the
  canonical state.
