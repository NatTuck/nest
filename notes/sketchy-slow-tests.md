# Sketchy slow tests

Notes from the `#21` easy-cleanup pass. This file records what is **not** an easy
fix: number/policy calls that need a human, sites deliberately left alone, and
anything left failing. The easy cases were fixed in place; this is the residue.

Scope of the pass: the test harness (`test/support/**`, `test/test_helper.exs`,
`test/mix/**`). The test files themselves were handled separately.

---

## 1. The 2000 ms cap (superseded — §11 has the bounds in force)

`#21`'s rule was **no test-side timeout may exceed 2000 ms.** Five sites in the
harness were over it (a sixth was deliberately raised *to* it — the
`park_llm_requests/1` row below). Three things have moved since, and all three
are recorded below: the global per-test ceiling is now **3000** (raised so a fence
can report its own failure instead of dying as an `ExUnit.TimeoutError` — see §2,
§3), the fences are **1000 ms** except for two files' shared `@turn_fence_ms`
constants at **2000** (see §11), and the two park valves are gone entirely (§4).

| site | was | then | note |
|---|---|---|---|
| `test/test_helper.exs` | `ExUnit.configure(timeout: 5_000)` | `2_000` → `3_000` | the global per-test ceiling — see §2 |
| `test/support/agent_turn_test_helpers.ex` (`park/3`) | `3_000` | `2_000` → removed | the valve timer was a race, not a safety net — see §4 |
| `test/support/agent_turn_test_helpers.ex` (`park_llm_requests/1`) | `1_000` | `2_000` → removed | **raised**, deliberately, then removed — see §4 |
| `test/support/agent_test_lifecycle.ex` (`wait_for_pid_down/3`) | `5_000` | `2_000` | unified with the delegate — see §5 |
| `test/support/agent_test_lifecycle.ex` (`stop_pid/2`) | `5_000` | `2_000` | same |
| `test/support/models_test_helpers.ex` (`await_models_refresh/1`) | `5_000` | `2_000` | see §6 |

Not changed, because they are **not** timeouts: `ShellCmd.default_timeout_ms() ==
60_000` and the `receive_timeout:` values assert *production* config, and
`exit({:normal, {GenServer, :call, [..., 5000]}})` / `{:timeout, {GenServer,
:call, [Nest.Models, :list, 5000]}}` simulate production error tuples.

## 2. The global per-test ceiling — the ruling, and what it exposes

The ruling was that **every** timeout in the tests, implicit or explicit, was
2000 ms or lower, with no exceptions: *"If a test can't run under that, we need
to fix it or consider removing it as untestable."* The per-test ceiling is
implicit, so it was 2000 ms. (It was briefly restored to 5000 on the argument
that a failure detector is not a wait; that argument is overruled.)

**It is 3000 ms today**, and the reason is §3's rule rather than a retreat from
the ruling: a fence that sits *at* the ceiling can never report its own failure,
so the ceiling was raised above the fences (which are 1000 ms) to let a fence
fail as a missing frame instead of as an opaque `ExUnit.TimeoutError`.

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
is milliseconds. The per-test ceiling (2000 ms when these runs were taken; 3000
today) is not threatened by any single test; what threatens it is setup latency
under concurrency, which is §10.

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
  per test (`test/support/agent_test_helpers.ex:505`), and every test in the
  suite shares that one coordinator process. It is a third-party library, so
  this cannot be de-serialized without forking Mimic.
- one blocked in `Nest.Agents.Supervisor.start_under_supervisor/2`
  (`lib/nest/agents/supervisor.ex:107`).
- one blocked in `code_server.call/1` (lazy module load inside the endpoint).
- one blocked in `Postgrex.Protocol.recv_bind` (DB contention).

Both shared points are written up as their own work in §10. Neither was fixed
*here* (in the timeout-capping branch: a supervisor-concurrency rewrite does not
belong in one). §10a has since been addressed; §10b has not.

**It also buys nothing for the gate.** The suite's 5 s budget
(`scripts/precommit-test.sh`) is *throughput* across `max_cases` concurrent
tests, not the deadline of any single test. The suite measured 6.4–8.3 s ExUnit
with the ceiling at either value, so lowering it cannot move the suite toward
5 s — it only converts slow tests into failed ones.

## 3. A fence at exactly the ceiling can never fire

`test/nest/agents/agent/turn_acceptance_test.exs:136` used
`assert_receive {:chat_status, %{status: "idle"}}, 2000` — the *same* value as the
then-ceiling. The ExUnit timeout therefore always won, and the test reported a
bare `ExUnit.TimeoutError` instead of the fence's own diagnostic.

**General rule this exposes:** a fence must sit *strictly below* the per-test
ceiling, or its failure is reported as an opaque test timeout. Both numbers moved
to satisfy it: the fences are **1000 ms** today (that call site included — the two
2000 ms exceptions §11 lists are still strictly below the ceiling, so they can
report their own failure), and the ceiling is **3000 ms**.

## 4. The park safety valves — removed, and why

`agent_turn_test_helpers.ex` documented an invariant: a *decisive* park must be
released within one turn fence, and the safety valve **must stay strictly longer
than the fence** so a slow host fails the fence instead of silently flipping the
outcome the park pins.

The cap collided with it: the valves could be at most 2000, so the fence had to
sit below them, and `@turn_fence_ms` (`sub_agent_tools_helpers.ex`) was moved
**2000 → 1800** with both valves at **2000**:

- `park/3`: 3000 → 2000 (still > 1800 ✓).
- `park_llm_requests/1`: 1000 → 2000. That was a **raise**, and a *correctness*
  fix, not a smell-avoidance: at 1000 ms the valve was **shorter than the fence**,
  so it could flip a parked outcome instead of letting the fence report. It was
  violating its own invariant.

**Both valves are gone now, and so is `@turn_fence_ms`.** The timer's only job
was "the owner went away", and the owner going away is directly observable
(`Process.monitor/1` + `:DOWN`), so the timer was never a safety net — it was a
race: it could fire while the owner was still running and let the worker proceed,
silently flipping the outcome a decisive park pins. Removing it removes the
"valve > fence" constraint instead of trading one number against another. The
idle fence's bound is now **1000 ms** (`SubAgentToolsHelpers.@idle_fence_ms`).

**What is left of the measurement, deliberately:** the fence's 1000 ms was
chosen from the same numbers (in-suite p50 18.7 ms / max 34.3 ms over 40 samples;
p50 926 ms / max 1534 ms under 48 CPU burners; a 500 ms fence missed outright at
seed 200984). 1000 ms is ~53× the in-suite median and clears the in-suite spread
with headroom, but it is **inside the observed spread** of the extreme-load
measurement, so it can fire there. That failure is loud (a missing frame, from the
fence's own bound) and is the outcome the ruling asks for — but it is a real
narrowing of the margin and a candidate to revisit.

## 5. `wait_for_pid_down` — unified, and why 2000 rather than something smaller

The same helper was exported with **two defaults 50× apart**:
`agent_test_lifecycle.ex`'s `wait_for_pid_down/3` = `5_000`,
`agent_test_helpers.ex:60` (the `defdelegate`) = `100`. Both are now **2000**, and
the delegate's doc/code mismatch is fixed (it documented the 100 ms path while the
code took the 5000 ms one).

Note the split was **backwards from intuition**: the *hot* `on_exit` paths got the
long value for every test that starts an agent, while two hand-written call sites
(`supervisor_subagent_test.exs:390`, `visibility_test.exs:180`) got 100 ms. The
count of those hot paths is what `grep -rn "start_agent(" test/` shows: **214
occurrences across 61 files** (including the definition at
`agent_test_helpers.ex:130`), i.e. at most **213 call sites** — the earlier "243"
here was not reproducible from the tree.

**Why 2000 and not the audit's suggested 500:** the helper is
`Process.monitor/1` + a single `:DOWN` receive, so the value is **pure
headroom** — it costs nothing on the happy path and only bounds a failure. On
expiry `stop_pid` returns `:ok`, and the *test* then fails later via
`assert_zero_remaining!/1`. A too-short window therefore converts "wait a bit
longer" into a teardown failure, and the doc explicitly warns that "a busy
scheduler can push shutdown past a fixed short window" because `terminate/2`
walks the descendant tree and removes the tmp directory. Since a long ceiling is
free and a short one is a flake, 2000 (then the cap; the deadline is 3000 today,
so it could be raised) is the risk-minimal choice.
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

## 7. `:sys.get_state` — explicit timeout, and where it is "cheating"

Almost every `:sys.get_state/2` site passes an explicit timeout. The values in
force: **1000 ms** for the harness's reads (the fence bound, so a read can never
outlive the fence that ordered it), **500 ms** for the ones that read a channel's
or the reloader's state (`test/nest_web/surgical_reloader_test.exs`,
`test/nest_web/channels/lobby_channel/providers_test.exs`,
`test/nest_web/channels/lobby_channel_rescan_models_test.exs`), and **250 ms** for
`AgentTestLifecycle`'s answer wait (`@answer_ms`, §11). **One site is
bare** — `test/nest/agents/agent/watch_test.exs:435` — and is deliberately not
fixed here. `issue-21-accessor-swaps` has since landed without it: the site reads
two fields (`workspace_path` + `tmp_path`) off one snapshot, so it was outside
that batch's single-field rows, and one `get_public_info/2` call covers both —
still open, see §11.

`:sys.get_state/2` takes the timeout second; `:sys.replace_state/3` takes it
**third** (`(Name, Fun, Timeout)`) — worth knowing, since the natural-looking
`:sys.replace_state(pid, 500, fun)` compiles and then fails at runtime with a
`FunctionClauseError` inside `:gen.call/4`.

Two distinct kinds of site, and only the second is a problem:

**Legitimate fixtures** — the test *forces* a state it cannot otherwise reach:
`set_status/2` and `fill_inbox/2` (`timeline_test_helpers.ex`),
`send_compaction_done/3` and `swap_to_mock_client/1` (`agent_test_helpers.ex`),
`record_read_file/2` (`agent_test_assertions.ex`). Keep.

**Barriers that read instead of waiting.** These are the sites the user asked
about; the first one has since been fixed:

| site | what it does |
|---|---|
| `sub_agent_tools_helpers.ex` (`idle?/1`) | *deleted.* It decided "the agent is idle" by reading `Machine.status_for(:sys.get_state(pid).live.machine)` rather than waiting on the `chat:status` broadcast, and its doc justified the choice (a missed broadcast can never be the reason a test fails) — but it also meant a broadcast regression could pass as a success. `await_idle/1` now fences on the agent's own `{:chat_status, %{name: name, status: "idle"}}` frame, and `test/nest/agents/agent/idle_fence_test.exs` pins that the fence fails when no frame arrives. |
| `sub_agent_tools_helpers.ex` (`query_results/1`, `agent_texts/1`) | assert on the agent's internal transcript state instead of the messages it broadcast. |
| `sub_agent_tools_helpers.ex` (coordinator start) | a bare `:sys.get_state(pid)` used purely as a readiness barrier, asserting nothing. |

`agent_test_lifecycle.ex`'s teardown was a fourth read until `#21`'s teardown
change: the status now comes from the agent *itself* (`Agent.ClientAPI.get_status/2`
→ `Machine.status_for/1`, evaluated in the agent's own process), and every status is
read *before* any agent is stopped — the teardown's own stops perturb the agents it
is about to read (stopping a batch's child makes its parent continue the batch), so
a read taken after a stop would report the cleanup's state, not the test's. The
harness's teardown path therefore has no `:sys.get_state` read left in it.

## 8. `eventually` — the helper, not the call sites

- **The stale claim is corrected** in both `eventually.ex`'s moduledoc and
  `test/support/credo/no_sleep_in_tests.ex`: it is not "a small number of
  tests", it was **73 call sites across 30 files** — and it is **9 across 4
  files** today (`agents_batch_test.exs`'s mailbox-length poll,
  `clone_agent_chat_stop_test.exs`'s six registry/`ChildRegistry` polls,
  `timeline_emitters_test.exs`'s timeline-file poll, and
  `supervisor_spawn_test.exs`'s registry poll). The rest became fences on the
  frame that decides them.
- **Nothing relies on the 500 ms default.** Verified by walking every call site
  (balancing parentheses) rather than grepping: all 9 pass an explicit `:timeout`,
  and so do the helper's own 3 call sites in `eventually_test.exs`. So the default
  is not load-bearing today and its value does not affect the suite.
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
  polling-only. Deciding this changes the remaining call sites, so it is a call
  for the human.
- The failure message reports only the budget, not the last observed value, and
  a `fun` that raises aborts the wait immediately instead of retrying. Both were
  left as-is deliberately — the call sites depend on the current behaviour, so
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
value is that a *hang* now costs 3 s instead of 5 s, and that lowering the ceiling
to 2000 ms — the value these runs used — started exposing the `Mimic.allow/3`
serialization in §2.

All runs were taken while two other agents were running the suite concurrently,
at load 6.9–10.5, so the wall times are upper bounds.

## 10. The two shared serialization points — their own work, not part of #21

Both were found by lowering the per-test ceiling and reading the stack traces.
Both were real, and each deserved its own change with its own review. **Do not
fold either into a timeout branch.** §10a has since been addressed; §10b has not.

### 10a. `Nest.Agents.Supervisor` — addressed; what remains is `init/1`

**The defect this section recorded is gone.** `Nest.Agents.Supervisor` is a
`DynamicSupervisor` (`lib/nest/agents/supervisor.ex:47`), not a `GenServer` with a
start `handle_call`: `start_under_supervisor/2` is
`DynamicSupervisor.start_child(@supervisor_name, {Agent, attrs})`
(`lib/nest/agents/supervisor.ex:107`), and the work that used to happen inside the
callback now happens in the *caller* — `fetch_or_start_agent/2` runs
`Persistence.build_attrs_for_start/2` and `Agent.pre_load_heal/1` before it asks
the supervisor for a child, and `Init`'s moduledoc records that `init/1` is pure
(no DB access). The failure that exposed the old shape:

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

That was a **production scaling defect**, not a test problem: it is why
agent-starting tests needed milliseconds-to-seconds rather than tens of ms, and the
fix taken is the shape this section proposed — only registry/child-spec bookkeeping
is left in the supervisor, and each start does its own DB work in the caller. **What
is still serialized** is OTP's own shape: `DynamicSupervisor.start_child/2` runs the
child's `start_link`/`init/1` in the supervisor process, so a slow `init/1` still
blocks every other start. That is why `test_helper.exs` warms the init path (see its
comment), not why a ceiling is needed.

### 10b. `Mimic.allow/3`'s single global coordinator

`test/support/agent_test_helpers.ex:505` (`allow_mimic_stubs/1`) calls
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
| fences (`assert_receive`/`refute_receive`/`assert_push`/`refute_push`) | **1000 ms**, two files at **2000 ms** | the ruling: raise every 500 to 1 s. The exceptions share one `@turn_fence_ms 2_000` between their idle fences and their `{:chat_message, …}` fences (`agent_chat_mode_test.exs:24`, `agent_stream_error_test.exs:40`), so splitting it would retune a non-idle timeout — left for the human. All of them sit below the per-test deadline, so a missed fence reports as a fence, not as `ExUnit.TimeoutError`. |
| `:sys.get_state`/`:replace_state` bounds, and the `ClientAPI` accessor reads that replaced the converted ones (`get_public_info/2`, `get_messages/2`, `get_total_usage/2`) | **1000 ms**, **500 ms** for the channel/reloader reads, **250 ms** for the teardown's answer wait | free on a healthy process; buys headroom under load. The accessors' own default is OTP's 5 s (production callers want that); only the converted test sites pass the explicit bound. One bare site (`watch_test.exs:435`) is still open — see §7. |
| `AgentTestLifecycle`'s answer wait (`@answer_ms`) | **250 ms** | the one exception, and it goes **down**. Not a fence and not a measurement: it caps how long the teardown waits for one agent to answer its own status question (`Agent.ClientAPI.get_status/2`) before giving up on it and stopping it anyway, so a long bound costs N x bound per teardown (500 ms x N is what blew a 2000 ms deadline). What it decides is the guard's one blind spot — an agent busy past it is not diagnosed as in flight (pinned by a test; see the sizing note below). |
| `refute_receive ..., 0` | **0** | a deliberate non-wait, not a fence. |
| per-test deadline (`ExUnit.configure`) | **3000 ms** | a failure bound, deliberately above the fences. |
| `max_cases` | **physical cores** | `Nest.Test.MaxCases.real_cpus/0`; measured 8 cases -> 0 failures, 16 -> 2, 24 -> 12. **No ceiling**: a 32-core/64-thread host gets 32. |

**Answer-wait sizing.** The old probe's 250 ms was unsized, and its own comment
said so: a synthetic saturation probe (32 yield-loops, then 16 blocked + 16
allocating workers) starved a *parked* process past a 5 s bound, so it could not
size anything. `#21`'s teardown change replaced the probe with a question the agent
answers about itself, so a non-answer is no longer a status. `@answer_ms` is kept at
250 — the probe's value — so what one agent can cost the teardown (`@answer_ms` +
`@stop_ms`) is exactly what the probe plus the stop cost before.

*The one measurement behind it, and what it cannot say.* Temporarily instrument
`AgentTestLifecycle.agent_status/1` to append
`System.monotonic_time(:microsecond)` deltas (one line per read) to a file, then:

    rm -f /tmp/teardown-probe/probe.log && mix test --max-cases 16 --seed 12345
    awk -F'\t' '{print $1}' /tmp/teardown-probe/probe.log | sort -n | \
      awk '{a[NR]=$1} END {print "n="NR, "p50="a[int(NR*0.5)], "p99="a[int(NR*0.99)], "max="a[NR]}'

473 reads: p50 21 us, p90 44 us, p99 84 us, p99.9 308 us, max 3.3 ms. Three
caveats, and they matter:

  * it is **one run**, on one host, at `max_cases: 16` (seed 12345);
  * it is **right-censored**: a read that does not answer inside the bound is
    reported as a timeout, not as a latency, so the sample says how fast a healthy
    agent answers when it answers — never how often one fails to;
  * it does **not** license "250 ms decides nothing". The bound does decide: an
    agent busy in its own loop for longer than it is not *diagnosed* as in flight,
    and `agent_test_lifecycle_test.exs` pins that boundary as a test rather than a
    comment. The loaded measurement already in the tree
    (`sub_agent_tools_helpers.ex`'s 48 CPU burners: p50 926 ms, max 1534 ms) shows
    a 250 ms wait *can* be reached under load. What is gone is only the old
    reading: a non-answer is no longer a status, so a *starved* agent can no longer
    be reported as in flight — and, symmetrically, a slow-but-busy one can no
    longer be caught.

**Behaviour change, recorded deliberately.** `agent_status/1` used to read
`:sys.get_state(pid, 250)` and invert the signal: an agent that did not answer was
`:unresponsive`, which `@in_flight_statuses` counted as in flight. That read the
*only* non-answer this suite actually produces — an agent that is already dying
because the test body stopped it — as a turn in flight, and failed a healthy test.
The teardown now asks the agent for its own status (`Agent.ClientAPI.get_status/2`),
for every owned agent before any of them is stopped: an answered status is the signal
(`:streaming`/`:executing_tools`/`:compacting`), a process that is gone or dying
answers `nil`, and a process that never answers is reported by `still_alive`
instead. A *mid-turn* agent still answers — a turn runs in
a worker task, not in the agent's loop — so the check still catches exactly what it
exists to detect.

**Recorded, not fixed here — `DBConnection.ConnectionError` (test isolation).**
A run logged a real connection error through `Agent.Persistence.append_message/3`:
a spawned agent was still appending when its owning test process exited, so the
sandbox connection was invalidated mid-query (`owner #PID<…> exited` / `Client … is
still using a connection from owner`). This is a genuine isolation defect and is
probably the mechanism behind agents that do not die in teardown. Its own change.

**Recorded, not fixed here — `stop_pid/2`'s `@stop_ms` wait.** A second per-agent
N x multiplier in the same teardown path. It only bites on a genuinely wedged
agent, but when it does the failure is a `TimeoutError` rather than
`assert_zero_remaining!`'s informative message. Lower priority than the answer
wait, same shape.

**Result at the new defaults** (`issue-21-timeout-sweep`, seed 200905, `max_cases:
16`, per-test 3000): **2372 tests, 0 failures**, ExUnit 7.4 s, wall 8.20 s, load
2.81 before / 4.75 after. That count is the measurement's, not the current one —
the suite has grown since. For comparison at the same 2000 ms deadline: 8 cases ->
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
* Still open from §7: `watch_test.exs:435`'s bare `:sys.get_state/1`, and its
  sibling at `:399` (which passes 1 s), each read `workspace_path` + `tmp_path`
  off one snapshot. One `get_public_info/2` call covers both fields, so each is a
  one-line conversion — they were simply outside the converted batch's
  single-field rows.
