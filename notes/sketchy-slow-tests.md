# Sketchy slow tests

Notes from the `#21` easy-cleanup pass. This file records what is **not** an easy
fix: number/policy calls that need a human, sites deliberately left alone, and
anything left failing. The easy cases were fixed in place; this is the residue.

Scope of the pass: the test harness (`test/support/**`, `test/test_helper.exs`,
`test/mix/**`). The test files themselves were handled separately.

---

## 1. The 2000 ms cap

`#21`'s rule: **no test-side timeout may exceed 2000 ms.** Five sites in the
harness were over it.

| site | was | now | note |
|---|---|---|---|
| `test/test_helper.exs` | `ExUnit.configure(timeout: 5_000)` | `2_000` | the global per-test ceiling — see §2 |
| `test/support/agent_turn_test_helpers.ex` (`park/3`) | `3_000` | `2_000` | a park safety valve — see §4 |
| `test/support/agent_turn_test_helpers.ex` (`park_llm_requests/1`) | `1_000` | `2_000` | **raised**, deliberately — see §4 |
| `test/support/agent_test_lifecycle.ex` (`wait_for_pid_down/3`) | `5_000` | `2_000` | unified with the delegate — see §5 |
| `test/support/agent_test_lifecycle.ex` (`stop_pid/2`) | `5_000` | `2_000` | same |
| `test/support/models_test_helpers.ex` (`await_models_refresh/1`) | `5_000` | `2_000` | see §6 |

Not changed, because they are **not** timeouts: `ShellCmd.default_timeout_ms() ==
60_000` and the `receive_timeout:` values assert *production* config, and
`exit({:normal, {GenServer, :call, [..., 5000]}})` / `{:timeout, {GenServer,
:call, [Nest.Models, :list, 5000]}}` simulate production error tuples.

## 2. ⚠️ The global 2000 ms ceiling currently fails tests — needs a decision

`test_helper.exs`'s per-test ceiling came down from 5000 to 2000. At the same
machine load:

| run | ceiling | result |
|---|---|---|
| baseline | 5000 | **2372 tests, 0 failures** |
| seed 940660 | 2000 | 2372 tests, **9 failures** |
| seed (quiet attempt) | 2000 | 2372 tests, **13 failures** |

**The failures are not "these tests need more than 2 s of work".** Reading the
stack traces, they are almost entirely **serialization points** that the longer
ceiling was hiding:

- **6 of the 9** in the first run blocked in `Mimic.allow/3` →
  `GenServer.call` on the **single global `Mimic.Coordinator`**. `start_agent/1`
  performs three of these per test (`agent_test_helpers.ex:495`), and every test
  in the suite shares one coordinator process.
- one blocked in `code_server.call/1` (lazy module load inside
  `Plug.Static.init`).
- one blocked in `Postgrex.Protocol.recv_bind` (DB contention).

That is a **real finding**: `Mimic.allow/3`'s global coordinator is a
suite-wide serialization point, and a 5 s ceiling made it invisible. Fixing it
(per-shard `allow`, or fewer calls per `start_agent/1`) is architectural and is
**not** part of the easy pass.

**I could not cleanly attribute these to the ceiling versus load**, because two
other agents were running the suite concurrently for the whole pass; the runs
above are at load 6.9–10.5. The ceiling is nonetheless the discriminator: the
identical suite is 0-failure at 5000 under the same load.

**Decision needed:** fix the `Mimic.allow/3` serialization, or accept a per-test
ceiling above 2000.

## 3. A fence at exactly the ceiling can never fire

`test/nest/agents/agent/turn_acceptance_test.exs:136` uses
`assert_receive {:chat_status, %{status: "idle"}}, 2000` — the *same* value as the
global per-test ceiling. The ExUnit timeout therefore always wins, and the test
reports a bare `ExUnit.TimeoutError` instead of the fence's own diagnostic.

**General rule this exposes:** if the per-test ceiling is 2000, fences must sit
*below* it — 1500 leaves the fence room to report first. Capping every fence at
exactly 2000 silently converts every fence failure into an opaque test timeout.

## 4. The park safety valves (invariant vs cap)

`agent_turn_test_helpers.ex` documents an invariant: a *decisive* park must be
released within one turn fence, and the safety valve **must stay strictly longer
than the fence** so a slow host fails the fence instead of silently flipping the
outcome the park pins.

The cap collides with it: the valves may be at most 2000, so the fence must sit
below them. `@turn_fence_ms` (`sub_agent_tools_helpers.ex`) therefore went
**2000 → 1800**, and both valves to **2000**.

- `park/3`: 3000 → 2000 (still > 1800 ✓).
- `park_llm_requests/1`: 1000 → 2000. This is a **raise**, and it is a
  *correctness* fix, not a smell-avoidance: at 1000 ms the valve was **shorter
  than the fence**, so it could flip a parked outcome instead of letting the
  fence report. It was violating its own invariant.

**The trade, recorded deliberately:** `@turn_fence_ms`'s 2000 was chosen from a
measurement (in-suite p50 18.7 ms / max 34.3 ms over 40 samples; p50 926 ms /
max 1534 ms under 48 CPU burners; a 500 ms fence missed outright at seed
200984). At 1800 it is still ~52× the in-suite median, but it is now **inside
the observed spread** of the extreme-load measurement, so it can fire where 2000
would not. That failure is loud and is the outcome the invariant asks for — but
it is a real narrowing of the margin and a candidate to revisit.

## 5. `wait_for_pid_down` — unified, and why 2000 rather than something smaller

The same helper was exported with **two defaults 50× apart**:
`agent_test_lifecycle.ex:72` = `5_000`, `agent_test_helpers.ex:54` (the
`defdelegate`) = `100`. Both are now **2000**, and the doc/code mismatch at
`agent_test_helpers.ex:256` is fixed (it documented the 100 ms path while the
code took the 5000 ms one).

Note the split was **backwards from intuition**: the *hot* `on_exit` paths that
run for every one of the 243 `start_agent/1` tests got the long value, while two
hand-written call sites (`supervisor_subagent_test.exs:377`,
`visibility_test.exs:180`) got 100 ms.

**Why 2000 and not the audit's suggested 500:** the helper is
`Process.monitor/1` + a single `:DOWN` receive, so the value is **pure
headroom** — it costs nothing on the happy path and only bounds a failure. On
expiry `stop_pid` returns `:ok`, and the *test* then fails later via
`assert_zero_remaining!/1`. A too-short window therefore converts "wait a bit
longer" into a teardown failure, and the doc explicitly warns that "a busy
scheduler can push shutdown past a fixed short window" because `terminate/2`
walks the descendant tree and removes the tmp directory. Since a long ceiling is
free and a short one is a flake, 2000 (the cap) is the risk-minimal choice.
**Lowering it needs a measurement, not a preference.**

**Compound cost, still present:** `stop_test_agents/0` calls `stop_pid/1` once
per owned agent with no caller timeout, so the worst case is *N* × 2000 ms, not
2000 ms. `notes/review-d1.md:294` already flags this.

## 6. `await_models_refresh/1` is coupled to a producer deadline

Its 5000 → 2000. The audit's finding stands and is worth keeping: the value is
**deliberately coupled to the producer's own 5000 ms scan deadline** in
`Nest.Models`. A consumer that gives up at 2000 will now report a timeout for a
scan the producer still considers in-flight. That is arguably the right
tightening (a scan taking >2 s should fail a test), but it is a coupling, not an
independent number, and it should be decided together with the producer's
deadline rather than one at a time.

## 7. `:sys.get_state` — explicit 500 ms, and where it is "cheating"

All 11 sites in the harness now pass an explicit `500`. `:sys.get_state/2` takes
the timeout second; `:sys.replace_state/3` takes it **third** (`(Name, Fun,
Timeout)`) — worth knowing, since the natural-looking
`:sys.replace_state(pid, 500, fun)` compiles and then fails at runtime with a
`FunctionClauseError` inside `:gen.call/4`.

Two distinct kinds of site, and only the second is a problem:

**Legitimate fixtures** — the test *forces* a state it cannot otherwise reach:
`set_status/2` and `fill_inbox/2` (`timeline_test_helpers.ex`),
`send_compaction_done/3` and `swap_to_mock_client/1` (`agent_test_helpers.ex`),
`record_read_file/2` (`agent_test_assertions.ex`). Keep.

**Unjustified barriers — the test peeks at internals instead of asserting
observable behaviour.** These are the sites the user asked about:

| site | what it does |
|---|---|
| `sub_agent_tools_helpers.ex` (`idle?/1`) | decides "the agent is idle" by reading `Machine.status_for(:sys.get_state(pid).live.machine)` rather than waiting on the `chat:status` broadcast. Its doc *justifies* the choice (a missed broadcast can never be the reason a test fails, and the condition matches the teardown invariant) — which is a real argument, but it does mean 67 `eventually` sites are asserting on internal state. |
| `sub_agent_tools_helpers.ex` (`query_results/1`, `agent_texts/1`) | assert on the agent's internal transcript state instead of the messages it broadcast. |
| `sub_agent_tools_helpers.ex` (coordinator start) | a bare `:sys.get_state(pid)` used purely as a readiness barrier, asserting nothing. |

`agent_test_lifecycle.ex`'s `agent_status/1` is a fourth read, but it is the
teardown invariant itself, so it is justified.

## 8. `eventually` — the helper, not the call sites

- **The stale claim is corrected** in both `eventually.ex`'s moduledoc and
  `test/support/credo/no_sleep_in_tests.ex`: it is not "a small number of
  tests", it is **73 call sites across 30 files**.
- **Nothing relies on the 500 ms default.** Verified by walking every call site
  (balancing parentheses) rather than grepping: all 73 pass an explicit
  `:timeout`; the only four without one are inside `eventually.ex` itself. So the
  default is not load-bearing today and its value does not affect the suite.
- **The helper had no test at all.** Added
  `test/support/eventually_test.exs` (3 tests): it returns a truthy value
  *without sleeping first* (the `interval` is set to 3000 ms, so a regression to
  sleeping-first blows the per-test ceiling); it polls until the condition holds
  and returns the value; and it raises with the **caller's** budget — the
  regression that already happened once, when the message reported a *negative*
  remainder derived from a deadline the check had already passed.
- **Policy question left open:** is polling still the right default answer? Some
  call sites are strictly better served by `Process.monitor/1` +
  `assert_receive {:DOWN, …}` (process death) or by waiting on a real PubSub
  event. The registry/`:DOWN`-cleanup polls have no event and are genuinely
  polling-only. Deciding this changes ~30 files, so it is a call for the human.
- The failure message reports only the budget, not the last observed value, and
  a `fun` that raises aborts the wait immediately instead of retrying. Both were
  left as-is deliberately — 73 call sites depend on the current behaviour, so
  changing it is its own change.

## 9. Measurement

| run | ceiling | ExUnit reported | wall | failures |
|---|---|---|---|---|
| baseline | 5000 | 7.4 s | 8 s | 0 |
| seed 940660 | 2000 | 7.0 s | 8 s | 9 |
| seed (quiet attempt) | 2000 | 8.3 s | 9 s | 13 |

**The easy cleanup did not make the suite faster.** That is the expected result
and worth stating plainly: every site this pass touched was a *ceiling* —
`assert_receive`, a monitor-based `:DOWN` wait, or a `defdelegate` default — and
a ceiling costs nothing on the happy path. The suite's time is spent elsewhere
(compile/load, and the serialized tail of `async: false` modules). The cap's
value is that a *hang* now costs 2 s instead of 5 s, and that the 2000 ms
ceiling has started exposing the `Mimic.allow/3` serialization in §2.

All runs were taken while two other agents were running the suite concurrently,
at load 6.9–10.5, so the wall times are upper bounds.
