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

## 2. The global per-test ceiling is 2000 — the ruling, and what it exposes

The ruling is that **every** timeout in the tests, implicit or explicit, is
2000 ms or lower, with no exceptions: *"If a test can't run under that, we need
to fix it or consider removing it as untestable."* The per-test ceiling is
implicit, so it is 2000 ms. (It was briefly restored to 5000 on the argument
that a failure detector is not a wait; that argument is overruled.)

**There is no slow *test* to fix.** The `--slowest 30` run put
`test/nest_web/channels/lobby_channel/invites_test.exs:91` at 1680 ms (next:
918 ms), which looked like a serial outlier at 84 % of the ceiling. It is an
artifact of that run's mode: `--slowest` forces `max_cases: 1` **and trace
output**, so the first test of each file absorbs that file's one-off cost
(lazy module load, DB connection establishment, code-server warm-up) and ExUnit
attributes it to whichever test's timer encloses it. Re-running the same file
alone in the same mode:

```
test revoke_invite/2 returns :ok when id arrives as a JSON integer ... (5.2ms)  <- the "1680 ms" test
test create_invite/2 returns {:error, too_many_invites} after 10 invites (73.2ms)  <- the file's real slowest
9 tests, 0 failures — Finished in 0.2 seconds
```

So the slowest *real* test in that file is 73 ms, and the per-test distribution
is milliseconds. The 2000 ms ceiling is not threatened by any single test; what
threatens it is setup latency under concurrency, which is §10.

The consequence is that the tests which lose a scheduling race now **fail
visibly** instead of being hidden by a longer deadline, and the failure set is
**unstable** — three consecutive runs gave 9, 11 and 6 failures with only one
test common to the first two — so this is not "six broken tests", it is
**whichever tests lose the scheduling race**. That makes it a mechanism problem,
and §10 is the mechanism.

| run | ceiling | result |
|---|---|---|
| baseline (main @ 3f4c0ec) | 5000 | 2372 tests, **0 failures** |
| cleanup branch, seed 940660 | 2000 | 2372 tests, **9 failures** |
| cleanup branch, quiet attempt | 2000 | 2372 tests, **13 failures** |
| cap branch, seed 17475 | 2000 | 2369 tests, **9 failures** |
| cap branch, seed 155072 | 2000 | 2369 tests, **11 failures** |
| merged branch, seed 155072 | 2000 | 2372 tests, **6 failures** |

A different set of tests each run — only one test was common to the cap branch's
first two runs — which is the definition of a flaky suite, and `AGENTS.md` rates
a sometimes-failing test as much worse than an always-failing one.

**The failures were not "these tests need more than 2 s of work".** Every one
blocked in a *serialization point* that the longer ceiling had been hiding:

- **4 of the 6** in the merged run blocked in `Mimic.allow/3` →
  `GenServer.call` on the **single global `Mimic.Coordinator`**
  (`deps/mimic/lib/mimic.ex:344-347`). `start_agent/1` performs three of these
  per test (`test/support/agent_test_helpers.ex:499`), and every test in the
  suite shares that one coordinator process. It is a third-party library, so
  this cannot be de-serialized without forking Mimic.
- one blocked in `Nest.Agents.Supervisor.start_under_supervisor/2`
  (`lib/nest/agents/supervisor.ex:107`).
- one blocked in `code_server.call/1` (lazy module load inside the endpoint).
- one blocked in `Postgrex.Protocol.recv_bind` (DB contention).

Both shared points are written up as their own work in §10. They are **not**
fixed here: a supervisor-concurrency rewrite does not belong in a
timeout-capping branch.

**It also buys nothing for the gate.** The suite's 5 s budget
(`scripts/precommit-test.sh`) is *throughput* across `max_cases` concurrent
tests, not the deadline of any single test. The suite measured 6.4–8.3 s ExUnit
with the ceiling at either value, so lowering it cannot move the suite toward
5 s — it only converts slow tests into failed ones.

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

## 10. The two shared serialization points — their own work, not part of #21

Both were found by lowering the per-test ceiling and reading the stack traces.
Both are real, and both deserve their own change with their own review. **Do not
fold either into a timeout branch.**

### 10a. `Nest.Agents.Supervisor.start_under_supervisor/2` serializes agent starts

`lib/nest/agents/supervisor.ex:107` is a `GenServer.call` to the single
`Nest.Agents.Supervisor`, and the `handle_call` behind it performs the *entire*
agent start — the `agents` row insert, model/context-limit resolution, tmp-dir
creation and the child spec — inside that one callback. With `max_cases: 24`, N
tests starting an agent concurrently queue on that one process, so the Nth waits
for all N−1 before its own work begins. The failure that exposes it:

```
** (ExUnit.TimeoutError) test timed out after 2000ms
  code: {:ok, parent_name, parent_pid, _parent_id} = start_parent(vid)
  stacktrace:
    :gen.do_call/4
    GenServer.call/3
    lib/nest/agents/supervisor.ex:107: Nest.Agents.Supervisor.start_under_supervisor/2
    lib/nest/agents/supervisor.ex:148: Nest.Agents.Supervisor.start_pre_spawned/3
    test/support/agent_test_helpers.ex:142: Nest.Agents.AgentTestHelpers.start_agent/1
    test/nest/agents/agent/clone_agent_registration_test.exs:164: start_parent/1
```

This is a **production scaling defect**, not a test problem: it is why
agent-starting tests need milliseconds-to-seconds rather than tens of ms. The
shape of a fix is to keep only registry/child-spec bookkeeping in the supervisor
callback and let each start do its own DB work in the caller (or under a
per-space supervisor) — a real design change with its own fallout.

### 10b. `Mimic.allow/3`'s single global coordinator

`test/support/agent_test_helpers.ex:499` (`allow_mimic_stubs/1`) calls
`Mimic.allow/3` once per stubbed module per `start_agent/1` — three calls per
agent start. Each is a `GenServer.call` to the single global `Mimic.Coordinator`
(`deps/mimic/lib/mimic.ex:344-347`), so the whole suite serializes there. That is
test-infrastructure cost and is **not** fixable without forking Mimic (or
dropping Mimic for a per-process stub mechanism). Recorded so nobody spends
another afternoon re-deriving it.

```
** (ExUnit.TimeoutError) test timed out after 2000ms
  code: start_agent(%{
  stacktrace:
    :gen.do_call/4
    GenServer.call/3
    (mimic 2.4.2) lib/mimic.ex:345: Mimic.allow/3
    test/support/agent_test_helpers.ex:499: Nest.Agents.AgentTestHelpers.allow_mimic_stubs/1
    test/support/agent_test_helpers.ex:217: bridge_test_to_agent/3
    test/support/agent_test_helpers.ex:146: start_agent/1
```

Measured cost: with the ceiling at 2000 ms these two points accounted for 5 of
the 6 failures in the merged run (4 Mimic, 1 supervisor); the sixth was DB
contention. With the ceiling back at 5000 ms the suite is green, so neither point
is *currently* a failure — they are latent and load-dependent, and they are what
make a 2000 ms ceiling unworkable rather than merely tight.

## 11. The 1000/250/3000 split, and two recorded defects

**Bounds, as they now stand** (`issue-21-timeout-sweep`):

| bound | value | why |
|---|---|---|
| fences (`assert_receive`/`refute_receive`/`assert_push`/`refute_push`) | **1000 ms** | the ruling: raise every 500 to 1 s. Must stay well below the per-test deadline so a missed fence reports as a fence, not as `ExUnit.TimeoutError`. |
| `:sys.get_state`/`:replace_state` bounds, and the `ClientAPI` accessor reads that replaced the converted ones (`get_public_info/2`, `get_messages/2`, `get_total_usage/2`) | **1000 ms** | free on a healthy process; buys headroom under load. The accessors' own default is OTP's 5 s (production callers want that); only the converted test sites pass the explicit bound. |
| `AgentTestLifecycle`'s teardown probe | **250 ms** | the one exception, and it goes **down**. It is a *measurement*, not a failure bound: `stop_test_agents/0` probes every owned agent synchronously, so a long bound costs N x bound per teardown (500 ms x N is what blew a 2000 ms deadline). |
| `refute_receive ..., 0` | **0** | a deliberate non-wait, not a fence. |
| per-test deadline (`ExUnit.configure`) | **3000 ms** | a failure bound, deliberately above the fences. |
| `max_cases` | **physical cores** | `Nest.Test.MaxCases.real_cpus/0`; measured 8 cases -> 0 failures, 16 -> 2, 24 -> 12. **No ceiling**: a 32-core/64-thread host gets 32. |

**Probe bound sizing, honestly.** A synthetic saturation probe could not size the
250 ms: 32 yield-loops, and then 16 blocked + 16 allocating workers, each starved a
*parked* process past a 5 s bound, so neither shape is the suite's. 250 ms is
chosen for what the bound is *for* (cap teardown at 250 ms per unresponsive agent,
catch a wedged or mid-turn one), not from a distribution. Follow-up: log the real
probe-latency distribution from a 16-way run and revisit with data.

**Behaviour change, recorded deliberately.** `agent_status/1` used to fail *open*:
a busy agent did not answer in time, `:exit, _ -> nil`, and `nil` is not in
`@in_flight_statuses`, so `assert_zero_remaining!` **passed** — the check silently
missed exactly the case it exists to detect. It now returns `:unresponsive` (in
flight) when the process is alive but does not answer, and `nil` only when the
reason says the pid is gone (`:noproc`/`:normal`/`:shutdown`). A starved-but-healthy
agent therefore fails the test instead of passing silently. That is the intended
direction.

**Recorded, not fixed here — `DBConnection.ConnectionError` (test isolation).**
A run logged a real connection error through `Agent.Persistence.append_message/3`:
a spawned agent was still appending when its owning test process exited, so the
sandbox connection was invalidated mid-query (`owner #PID<…> exited` / `Client … is
still using a connection from owner`). This is a genuine isolation defect and is
probably the mechanism behind agents that do not die in teardown. Its own change.

**Recorded, not fixed here — `stop_pid/2`'s `timeout \\ 2_000`.** A second per-agent
N x multiplier in the same teardown path. It only bites on a genuinely wedged
agent, but when it does the failure is a `TimeoutError` rather than
`assert_zero_remaining!`'s informative message. Lower priority than the probe,
same shape.

**Result at the new defaults** (`issue-21-timeout-sweep`, seed 200905, `max_cases:
16`, per-test 3000): **2372 tests, 0 failures**, ExUnit 7.4 s, wall 8.20 s, load
2.81 before / 4.75 after. For comparison at the same 2000 ms deadline: 8 cases ->
0 failures, 16 -> 2, 24 -> 12.

**Recorded, not fixed here — the accessor reads, and what they cost.**
`issue-21-accessor-swaps` converted 106 `:sys.get_state/2` reads in the tests to
`ClientAPI` accessors, so the bound above now covers those calls too: the three
accessors take the `GenServer.call/3` bound as an optional second argument
(production default unchanged at OTP's 5 s), and every converted site passes
`1_000`. Two consequences worth keeping in view, neither a defect today:

* `get_public_info/2` builds the whole public map per call — `Inbox.serialize/1`
  over the queue, plus `Broadcasts.Usage.context_usage_map/4` →
  `ConversationSize.size/1` over the whole transcript
  (`lib/nest/agents/agent/broadcasts/usage.ex:177`). So an `await_idle`/`wait_idle`
  helper that calls it once per turn is O(transcript) per turn, where the
  `:sys.get_state/2` it replaced was O(1). The suite is still under 5 s and no
  fence moved, so this is recorded rather than optimised; if it ever matters, the
  fix is a narrower accessor for the fence helpers (the status alone), not a cache.
* §7's "all 11 sites in the harness now pass an explicit `500`", and its two
  `:sys.get_state` rows for `query_results/1` / `agent_texts/1`, are superseded:
  the harness bound is 1 s (this section), and those two helpers now read the
  transcript through `get_messages/2` with that bound.
* The `/1` accessor calls that are *not* converted sites keep OTP's 5 s, and so
  keep the diagnosis gap this change closed for the converted ones. 18 sites,
  its own batch, not this one: `turn_acceptance_test.exs:385,391`;
  `agent_observability_test.exs:218,261,310,318,362,399,406`;
  `agent_system_messages_test.exs:56`; `agent_tmp_path_test.exs:81,114`;
  `chat_task_crash_test.exs:153`;
  `supervisor_subagent_test.exs:99,198,315,316`; `agents_test.exs:579`.
  (`client_api_test.exs`'s six `/1` calls are deliberate: they pin the default.)
