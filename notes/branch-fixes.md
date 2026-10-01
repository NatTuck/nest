# `shell-bg` (PR #10) — fixes

Branch: `shell-bg` (commit `78f8ef3`, "Group tool capabilities and add background shell jobs").
This note is the working plan for the review fixes on that branch plus the
tool-call budget invariant work that the review surfaced.

Two parts:

- **Part A — PR review fixes.** The concrete defects found reviewing `shell-bg`.
- **Part B — tool-call budget invariant.** A pre-existing, broader flaw the
  review exposed; it must be fixed for the budget system to be sound, and it
  subsumes the shell-family portion of Part A's Fix 2.

---

## Part A — PR review fixes

### A1. Carry real agent identity into tool execution (blocking)

**Problem.** `shell-cmd background: true` and `shell-list`/`shell-wait`/
`shell-kill` read ownership from the per-call context, but the production
executor only forwards `caps`/`messages`/`context_limit`:

- `lib/nest/agents/agent/batch_sizer.ex:190-195` (`do_execute/2`) builds the
  context passed to `LLMTools.execute_one/3`.
- `lib/nest/tools.ex:172-176` (`shell_cmd/4`) reads `context[:space_id]`,
  `context[:agent_name]`, `context[:agent_pid]` → `{nil, nil}` / `nil`.
- `lib/nest/tools/shell_jobs.ex:147-149` (`agent_key/1`) reads with default
  `:unknown` → `{:unknown, :unknown}`.

Consequences on the real path (`ToolLoop.execute` → `run_batch` →
`BatchSizer.run` → `execute_one`): jobs are keyed under `{nil, nil}`, the
Agent pid is not monitored (`track_agent/3`, `shell_jobs.ex:304-319`), the
UI broadcast guard (`is_integer(space_id)`, `shell_jobs.ex:452`) never fires,
`Agent.terminate`'s `stop_all/1` uses the real key and matches nothing, and
the list/wait/kill tools (keyed `{:unknown, :unknown}`) can't see the job at
all. The tests pass only because they bypass this path (direct `ShellCmd.execute`
or a hand-built context).

**Fix.**

- `lib/nest/agents/agent/batch_sizer.ex` (`do_execute/2`): add `agent_pid`,
  `agent_name`, `space_id`, and `tmp_path` from `ctx` to the map handed to
  `LLMTools.execute_one/3`. Use `Map.get/3` so unit-test ctx maps that omit
  `space_id` keep working.
- Add a single `Nest.Tools.agent_key/1` helper (`{space_id, agent_name}` with
  `:unknown` defaults) and use it from both `shell_cmd/4` (`tools.ex`) and
  `Nest.Tools.ShellJobs.agent_key/1` so writer and readers always agree.

`ctx` already carries all four fields — built in
`lib/nest/agents/agent/chat_turn_spawner.ex:68-84`, stored verbatim at
`lib/nest/agents/agent/chat_turn.ex:129`; `agent_pid` is the Agent GenServer pid.

**Tests.**

- BatchSizer-level regression: ctx with real identity →
  `BatchSizer.run([shell-cmd background:true], ctx)` → assert the job is in
  `ShellJobs.list({space_id, name})` and `ShellJobs.list({nil, nil}) == []`.
  Fails before the fix.
- Optional end-to-end: drive `ToolLoop.execute/3` with `shell-cmd background`
  then `shell-list` and assert the job is listed.

### A2. `shell-wait` / `shell-list` honor the result cap, with honest projections

**Problem.** The three new tools are registered but have no `ProjectedSize`
clause, so the catch-all treats them as hallucinated names
(`projected_size.ex:64-77`). `shell-wait` is unbounded (a job's whole log) and
`shell-list`'s bytes are unbounded (each line embeds the job's full command),
yet BatchSizer's over-cap routing only covers `shell-cmd`/`file-read`; both fall
into "keep full anyway" (`batch_sizer.ex:396-402,424-427`). `max_result_tokens`
is advertised on `shell-wait`/`shell-list` but ignored.

**Fix.** Subsumed by Part B Phases 1–3: the shell family becomes
substitutable (path-and-head offload) and gets explicit `ProjectedSize`
clauses. No separate work item.

### A3. Unsubscribe waiters on abandoned waits

**Problem.** `ShellJobs.subscribe/3` (`shell_jobs.ex:163-176`) has no inverse.
The `shell-wait` timeout and `:stop_chat` paths and the `await_killed` timeout
(`lib/nest/tools/shell_jobs.ex:96-100,121-123`) all leave the caller pid in
`state.waiters`, which is only cleared when the job actually exits. A
long-running job with repeated waits grows the list unbounded and later sends
`{:shell_job_exit, ...}` to stale pids.

**Fix.**

- `lib/nest/sandbox/shell_jobs.ex`: add `unsubscribe/3` client API +
  `handle_call({:unsubscribe, agent_key, job_id, pid}, ...)` that removes `pid`
  from `state.waiters[job_id]` (delete the key when the list empties), via a
  private `remove_waiter/3`. Update the `subscribe/3` doc.
- `lib/nest/tools/shell_jobs.ex`: call `unsubscribe` on every non-completion
  exit — `wait/2` timeout, `wait/2` `{:stop_chat, _}`, and `await_killed/2`
  timeout. (On normal completion `notify_waiters/3` already removed the entry.)

**Tests.**

- Unit: `subscribe` then `unsubscribe` leaves
  `:sys.get_state(ShellJobs).waiters` without the pid/job id.
- Each abandoned path unsubscribes: `shell-wait` timeout, `shell-wait`
  `:stop_chat`, `await_killed` timeout.
- Assert via `:sys.get_state` (deterministic); do not use timed
  `refute_receive`.

### A4. Enforce `[shell] background` in all modes

**Problem.** `ProjectConfig.merge/4` (`lib/nest/project_config.ex:237-256`)
applies `[shell]` only when the mode writes `:workspace`, but
`ShellCmd.background_cap/1` (`lib/nest/tools/shell_cmd.ex:160-167`) defaults to
`1` whenever `caps["shell"]` is absent. So read-only modes always allow one
background job and cannot honor `background = 0`.

**Fix.** Restructure `merge/4` so `put_shell/2` always applies, while
`fs.project` + `fs.protected` stay gated on `is_binary(workspace) and
workspace_writable?(caps)`. Update the comment above `put_shell/2` and related
docs.

**Tests.** Flip the existing "does not merge the shell cap in a read-only mode"
case (`test/nest/project_config_test.exs`) to assert the cap **is** merged in a
read-only mode; keep the mount-gating tests unchanged.

### A5. Dropped — migration capability change

The group migration's capability escalation is an intentional replacement of
the old behavior. Not a work item.

---

## Part B — tool-call budget invariant

### The invariant

For a batch admitted by preflight, the cooked (inline) tool results must satisfy:

```
Σ inline_final(tool_i)  ≤  Σ projection(tool_i)  ≤  context_limit − messages − reserve
```

The projection for a tool is its **minimum substitutable size**. If a tool's
actual output can exceed that minimum, the tool must have a substitute that is
always ≤ projection and that `cook` applies whenever the result doesn't fit.
"Keep the full result anyway" is forbidden.

**Current violations.**

- `BatchSizer.fit_in_batch_budget/4` and `handle_over_cap/5`
  (`batch_sizer.ex:387-403,412-427`) keep full and log a warning for every tool
  other than `shell-cmd`/`file-read`.
- Sub-agent tools (`agents-spawn`, `agents-query`, `agents-list`,
  `agents-archive`, `agents-batch`, `models-list`) bypass BatchSizer entirely
  (`tool_loop.ex:104-119,134-143`), so they never pass through the budget pass.
  `agents-query` and `agents-spawn` with `query` return an entire agent
  response unbounded (`tool_loop.ex:205-223,321-328,452-457`).
- `ProjectedSize` has clauses only for `file-read`, `shell-cmd`, `file-write`,
  `file-edit`, `file-inspect`, `context-check`. Everything else (including all
  sub-agent tools and the three new shell tools) projects as a tiny "unknown
  tool" error string.

### Per-tool classification

| Tool | Can be large? | Mechanism | Projection clause |
| --- | --- | --- | --- |
| `file-read` | yes | over-cap → structured error (in-budget substitute) | stat-based estimate (already present) |
| `file-write` | no | fixed string | fixed string estimate |
| `file-edit` | no | fixed string | fixed string estimate |
| `file-inspect` | no | fixed metadata | fixed shape estimate (already present) |
| `shell-cmd` | yes | substitute (summary) | summary baseline (already present) |
| `shell-wait` | yes | substitute (summary) | summary baseline |
| `shell-list` | yes | substitute (summary) | summary baseline |
| `shell-kill` | no | fixed string | fixed string estimate |
| `context-check` | no | one line | fixed string estimate (already present) |
| `context-compact` | n/a | intercepted stub; stripped from preflight | n/a |
| `agents-spawn` | yes (with `query`) | substitute (summary) | summary baseline |
| `agents-query` | yes | substitute (summary) | summary baseline |
| `agents-list` | bounded | sliced to 4000 chars | slice-size estimate |
| `agents-archive` | no | fixed string | fixed string estimate |
| `agents-batch` | yes | substitute (offload) | summary baseline |
| `models-list` | bounded | sliced to 4000 chars | slice-size estimate |

### Phase 1 — generic substitute primitive

Extract the summary builder from `BatchSizer.build_summary_with_size/4`
(`batch_sizer.ex:436-470`) into a shared function, e.g.
`Nest.Agents.Agent.BatchSizer.Overflow.substitute(content, ctx, label,
budget_tokens, prefix)`:

- Write the full bytes to the agent scratch via `Overflow.write/4`
  (`batch_sizer/overflow.ex`); fall back to `"(temp file unavailable)"` when
  `tmp_path` is nil.
- Header: `"<label> (<N> tokens) saved to <path>."`.
- Head budget: `max(estimate(header) * 4, estimate(header) + 50)`, whole lines
  only (reuse `head_text/2`).
- Coerce invalid UTF-8 via `to_valid_utf8/1`; truncate the whole block to the
  remaining budget with `truncate_to_fit/2`.
- Return the inline string; it is guaranteed ≤ the caller's budget.

`BatchLoop.offload_if_needed/4` (`batch_loop.ex:471-484`) switches to this
helper so the head policy is uniform (it currently has its own fixed
`@offload_head_chars 200`).

Labels: `Command output of '<cmd>'` (shell-cmd, unchanged), `Output of
shell-wait <id>`, `Output of shell-list`, `Results of agents-batch (<n>
items)`, `Output of <tool>` fallback.

### Phase 2 — BatchSizer never keeps an over-budget result

- `handle_over_cap/5`: keep `shell-cmd` → substitute, `file-read` → error;
  replace the catch-all with the Phase-1 substitute.
- `fit_in_batch_budget/4`: the `true` branch substitutes instead of
  warning + keep-full.
- `apply_one_with_acc/3` (`batch_sizer.ex:288-294`): extend the binary-content
  branch from `tc.name == "shell-cmd"` to every substitutable tool.
- Remove the two "keeping full anyway" warnings (`batch_sizer.ex:397,425`).

This closes the overflow for regular tools even when a projection under-counts
(e.g. token-dense `file-read`, or a file that grows between stat and read).

### Phase 3 — sub-agent tools get substitutes + honest projections

- `ToolLoop.build_query_result/3` and `await_spawn_result/3`: if the response
  exceeds `CapCalculator.effective_max_result_tokens(tc, usable)`, substitute
  via the Phase-1 helper (guard `usable > 0`, as `BatchLoop` does at
  `batch_loop.ex:471-484`).
- Add `max_result_tokens` to the `agents-spawn`, `agents-query`, `agents-list`,
  and `models-list` schemas (`lib/nest/tools.ex`) so the model can lower the cap
  (only `agents-batch` has it today).
- `ProjectedSize`: add clauses for every registered tool missing one per the
  table above. Substitutable tools project `summary_baseline_size() *
  @safety_padding`; bounded tools project their real upper bound. This
  satisfies the module's own "registered-but-unprojected" contract.

### Phase 4 — one budget pass over the whole batch

Even with Phases 1–3, a cook that only accounted for regular tools would let a
mixed batch (regular + sub-agent) exceed. The budget pass is authoritative over
the whole batch:

- Implemented: `BatchSizer.run/2` is `execute/2` (preflight + execute → raw
  entries) followed by `cook/2` (the single keep-or-substitute pass). `ToolLoop`
  runs `BatchSizer.execute/2` for the regular tools, merges the sub-agent
  entries in input order, and calls `BatchSizer.cook/2` exactly once. There is
  no second cook.

`Σ inline_final ≤ limit` for the entire batch, independent of which family
produced each result.

### Tests

- BatchSizer: table-driven over every substitutable tool name — feed an
  oversized fake result, assert (a) inline size ≤ remaining budget, (b) the
  scratch file holds the full bytes, (c) no "keep full" warning.
- A test asserting the projected-tool set equals the registered tool set (add a
  `@doc false` introspection on `ProjectedSize` to avoid the private-API
  problem).
- ToolLoop: oversized `agents-query` / `agents-spawn(query)` are substituted;
  a mixed regular + sub batch stays ≤ budget.
- Keep the existing `batch_sizer_cap_test.exs` shell-cmd/file-read cases
  passing unchanged.

### Docs

- Update `notes/no-truncation-or-overflow.md` to state the invariant and the
  bounded-vs-substitutable split.
- Update the `BatchSizer` and `ProjectedSize` moduledocs' per-tool behavior
  lists.

---

## Verification

- `mix test` for the touched areas (`batch_sizer*`, `tool_loop`, `tools`,
  `shell_jobs`, `project_config`); write the full output under
  `notes/test-runs/` (never pipe to head/tail/grep).
- `mix precommit` and read the full output.
- No JS changes in this round, so `mix assets.*` is not required.
- Use `capture_log` for the expected substitute/error diagnostics so no logger
  output leaks into test output.

## Order of work

1. A1 (identity) — unblocks the feature and is independently testable.
2. A3 (unsubscribe) and A4 (all-modes enforcement) — small, independent.
3. B Phase 1 → 2 → 3 → 4 (Phase 2 subsumes A2).
