# Sketchy slow tests

Things in the Elixir suite that make it slow and were **not** fixed in the `#21`
easy-cleanup pass — either because the fix is a judgement call, or because
fixing it would weaken what the test proves. The user's rule for this pass was:
*"everything that doesn't have an amazing justification should be reported for
manual review"*, and *"report those that fail and can't be easily fixed rather
than reverting the delay reduction."*

Scope of the pass: `test/nest/agents/**`. The `test/support/**` harness,
`test/nest/**` (non-agents) and `test/nest_web/**` were covered by sibling
branches.

---

## 1. `eventually` — 61 call sites in 24 files, NOT reduced

This is the largest remaining item and it was deliberately left alone: each
replacement is a small restructuring, not a mechanical edit, and doing 61 of
them inside an easy-cleanup pass would have been a rewrite.

`Eventually.eventually/2` polls with a **10 ms interval** and a **500 ms default
budget**. Its own moduledoc and the `NoSleepInTests` credo check both describe
it as being used by *"a small number of tests"* — it is now 61 sites in 24
files, so the description has drifted.

**Genuinely polling-only (no event exists to wait on) — keep:**

- `test/nest/agents/agent/child_registry_test.exs:142`
- `test/nest/agents/agent/clone_agent_registration_test.exs:193`
- `test/nest/agents/supervisor_test.exs:183`
- `test/nest/agents/supervisor_subagent_test.exs:339`
- `test/nest/agents/supervisor_spawn_test.exs:416`

These poll `Registry` / `:DOWN`-cleanup state. There is no broadcast to wait on,
so polling is the correct primitive.

**Replaceable with a strictly better primitive — candidates for a follow-up:**

- `test/nest/agents/agent/agents_batch_test.exs:256` —
  `eventually(fn -> not Process.alive?(coordinator) end)`. A process-death wait,
  so `Process.monitor/1` + `assert_receive {:DOWN, …}` is exact, costs nothing,
  and cannot miss the event.
- `test/nest/agents/agent/batch_coordinator_test.exs:98` — `find_coordinator(gone)`,
  same shape, same fix.
- Several transcript polls have a real PubSub event behind them (a broadcast the
  suite already subscribes to elsewhere), which would let them become
  `assert_receive`. **These need reading one at a time to confirm the event
  exists before the wait** — a `refute`-shaped change here is how a real
  assertion gets silently weakened.

**Policy question for a human:** should `eventually` remain the default answer
for "wait for something", or should the suite push call sites toward
`Process.monitor/1` + `assert_receive {:DOWN, …}` for process death and a real
`assert_receive` for events, leaving polling only for genuinely event-less state?
The helper's moduledoc already assumes the answer is "a small number of tests",
which is no longer true.

Also worth a decision: `eventually/2` is itself **untested**. Nothing asserts the
two behaviours its own comment describes — that it returns the truthy value
without sleeping, and that it raises with the *caller's* budget (the comment
exists because an earlier version reported a negative remainder).

---

## 2. `:sys.get_state` used as a barrier — the "cheating" the user asked about

The pass made every `:sys.get_state`/`:sys.replace_state` in this scope pass an
explicit `500`, so a wedged agent now fails fast instead of hanging for OTP's
implicit 5000 ms default. **292 call sites across 45 files.**

Two sites are worth a human's eye because the synchronous state read is doing
work that a test should not really need:

- **`test/nest/agents/supervisor_spawn_test.exs:61`** — a **bare
  `:sys.get_state(pid, 500)` whose result is discarded.** It is a pure
  synchronization barrier: it asserts nothing, it only forces the agent to drain
  its mailbox. A barrier that asserts nothing is a smell — either the test needs
  to assert on the state it just fetched, or it should wait for the event it is
  actually interested in.
- **`test/nest/agents/chat_task_crash_test.exs:266`** —
  `eventually(fn -> :sys.get_state(pid, 500).live.machine.work.active_worker end)`.
  This **polls the agent's internal state** to discover a pid. The worker's
  existence is already observable: the stub sends `:worker_blocked` and the test
  receives it. Polling internal state to recover information the test was
  already sent is the clearest case of the pattern.

Neither was changed: both need a judgement about what the test should assert,
and changing them could silently weaken the test.

---

## 3. Number/policy calls that need a human

- **`test/nest/agents/agent_compaction_preflight_test.exs:154`** —
  `refute_receive {:chat_status, %{status: "context_overflow"}}, 200`. The
  audit called it *provably redundant*; **I could not verify that**, and the
  surrounding `assert_receive` uses a selective receive, so a stray
  `context_overflow` message would sit in the mailbox unconsumed rather than
  failing anything. Removing it could therefore delete a real negative
  assertion. Kept, and flagged here. It is this file's only real wall-time cost
  (200 ms).
- **`test/nest/agents/agent/watch_test.exs`** — the watch spec
  `{:agent_idle, 1, ["bob"], 2_000, false}`. The 4th element was `60_000` and was
  reduced to satisfy the 2000 ms cap. The test kills the caller and asserts
  `:DOWN` within 500 ms, so the deadline never fires and the reduction is
  behaviour-neutral — **but confirm that 4th element really is a timeout and not
  a semantic "far future" marker.**
- **`test/nest/agents/agent/turn/executor_test.exs:181`** —
  `run({:arm_timer, 2_000, :stop_timer})`, reduced from `5_000`. This is the
  *duration being armed*, not a wait, and the test cancels the timer
  immediately, so the reduction is harmless — but it is arguably fixture data
  rather than a timeout, and a reviewer may prefer it restored.
- **The three `@tag timeout:` values in `agent_context_warning_test.exs`** were
  `30_000` and are now `2_000` (the cap). **Their origin is unknown.** Nothing in
  that file can plausibly exceed ~200 ms, so the likely story is that they were
  added to accommodate three 5 s fences that the cap has now removed. If they
  were added for an observed flake, **that flake is a bug that should be found,
  not masked** (SMELLS.md) — escalating rather than assuming.

---

## 4. Left alone deliberately

- **`test/nest/agents/agent_tools_second_chance_test.exs:58`** (and a sibling) —
  a `capture_log/1` whose return value is discarded. SMELLS.md calls that a bug
  ("it can only hide prints"), but AGENTS.md also says capture-and-discard sites
  **may not be added to** without explicit user instruction, and this one is
  pre-existing. The honest fixes are to assert on the captured log or to drop
  the capture entirely; both need a human to decide which.
- **`assert Process.alive?(pid)`** appears at 8 sites in this scope
  (`supervisor_test.exs:177,250`, `supervisor_persistence_test.exs:88`,
  `chat_task_crash_test.exs:149` *(removed — the following
  `Agent.get_public_info/1` call already proves liveness)*,
  `chat_task_cleanup_test.exs:75`, `agent_recovery_test.exs:88`,
  `agent/turn_declined_delivery_test.exs:116`, `client_api_test.exs:133`).
  AGENTS.md discourages `Process.alive?/1` in tests. Each needs a look at
  whether the following line already proves liveness; that is a per-site read,
  not a mechanical edit.

---

## 5. The park-valve / 2000 ms-cap tension (harness, sibling branch)

Recorded here because it spans both scopes. `agent_turn_test_helpers.ex`
documents that a *decisive* `park` must be released within one turn fence, and
that the safety valve **must stay strictly longer than the fence** so a slow host
fails the fence instead of silently flipping the pinned outcome. The fence
(`SubAgentToolsHelpers.@turn_fence_ms`) is 2000 ms and the valve was 3000 ms — so
the 2000 ms cap and that invariant cannot both hold. The fence's 2000 ms is
**measured** (in-suite p50 18.7 ms / max 34.3 ms over 40 samples; p50 926 ms /
max 1534 ms under 48 CPU burners; a 500 ms fence missed outright at seed
200984), so lowering it is a real flake risk. Belongs to whoever owns
`test/support/**`.
