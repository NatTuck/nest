# `max_cases`: baseline data and the service-time curve

Two questions were asked here, and only one of them can be answered with the
hosts available:

1. **Can a function of CPU topology pick `max_cases`?** — *Not testable on two
   hosts.* One host (celedyr) falsifies the *current* derivation, but a rule is
   tested by hosts, and there are two. Nothing below should be read as a verdict
   on the topology question. What the data does give is the *mechanism*, which
   is what a future rule would have to model.
2. **What is the suite actually bottlenecked on as concurrency rises?** —
   Answered, with a curve.

## Method

* Revision `5a7a5c3` on every host; `--seed 12345` on every run so orderings are
  comparable; `--max-cases` 2, 4, 6, 8, 12, 16, 24, 32; one run per point; the
  load average recorded immediately before each run.
* The `--max-cases` CLI flag was confirmed to override
  `Nest.Test.MaxCases.real_cpus/0` (`max_cases: 3` observed with `real_cpus()`
  = 16), so the ladder measures what it claims to.
* `flock` per host, one suite at a time, so no two runs share a host.
* Harness: `notes/maxcases-ladder/ladder.sh`. Curve:
  `notes/maxcases-ladder/service_time.exs`. Calibration:
  `notes/maxcases-ladder/calibrate.exs`.
* Committed measurements: `notes/maxcases-ladder/{vampire,celedyr}.tsv` (ladder
  rows) and `notes/maxcases-ladder/{vampire,celedyr}-service-time.log` (curve).
  The per-point suite logs are large and live on each host beside the harness;
  this repo gitignores `notes/test-runs`, so they are not committed.

## Ladder: vampire (fast host)

Load 9.3–14.0 during the whole ladder — another agent was compiling on this box,
so these numbers are a **conservative** baseline, not a quiet one.

| cases | failures | detector | timeout | other | wall s | user s | load1 |
|---|---|---|---|---|---|---|---|
| 2 | 1 | 0 | 0 | 1 | 10.28 | 60.7 | 9.27 |
| 4 | 0 | 0 | 0 | 0 | 6.74 | 63.5 | 9.74 |
| 6 | 0 | 0 | 0 | 0 | 5.89 | 66.4 | 10.42 |
| 8 | 0 | 0 | 0 | 0 | 5.49 | 66.9 | 11.11 |
| 12 | 0 | 0 | 0 | 0 | 4.89 | 67.0 | 12.06 |
| 16 | 0 | 0 | 0 | 0 | 4.69 | 66.4 | 13.34 |
| 24 | 0 | 0 | 0 | 0 | 4.67 | 66.7 | 13.79 |
| 32 | 0 | 0 | 0 | 0 | 4.79 | 66.9 | 13.97 |

The single failure at 2 cases is a 1000 ms fence miss
(`lobby_channel_scoping_test.exs:386`, an `agent:status` broadcast) — a
concurrency *deficit*, not excess: at 2 cases there is not enough parallelism
for the broadcast to land inside the fence. Wall time bottoms out at 16–24
cases and rises again at 32.

## Ladder: celedyr (slow host), quiet box

Load at the start 2.09; the load column rises with the case count because the
suite *is* the load.

| cases | failures | detector | timeout | errlog | other | wall s | user s | load1 |
|---|---|---|---|---|---|---|---|---|
| 2 | 0 | 0 | 0 | 0 | 0 | 36.80 | 181.4 | 2.09 |
| 4 | 1 | 0 | 0 | 0 | 1 | 24.14 | 181.9 | 4.32 |
| 6 | 4 | 4 | 0 | 1 | 0 | 20.94 | 183.8 | 7.32 |
| 8 | 4 | 4 | 0 | 0 | 0 | 19.48 | 185.8 | 10.38 |
| 12 | 13 | 13 | 0 | 0 | 0 | 18.92 | 185.3 | 13.79 |
| 16 | 14 | 12 | 2 | 1 | 0 | 18.56 | 186.5 | 14.69 |
| 24 | 27 | 19 | 5 | 1 | 3 | 19.00 | 187.8 | 15.19 |
| 32 | 21 | 15 | 6 | 1 | 0 | 19.38 | 187.3 | 15.72 |

Two things worth reading off this table:

* **The teardown detector is the dominant failure class**, from 6 cases upward
  (4 of 4, 4 of 4, 13 of 13, 12 of 14, 19 of 27). `ExUnit.TimeoutError` only
  appears from 16 cases. So on this host the thing that breaks first is not a
  test's own deadline — it is the teardown bound.
* **User CPU is flat at ~181–188 s across the whole ladder.** Every point does
  the same work; only the wall clock and the failure count move. That is the
  signature of a queueing limit, not of running out of CPU.

### What is failing at the lowest failing case count (4 and 6)

At **4 cases**, the one failure is not the detector:
`reply_debt_test.exs:315`, `Supervisor.get_running_agent(space, name)` still
`{:ok, pid}` where the test expects `{:error, :not_found}`. This is an ordering
race and it is **not** load-only — it also appeared at 24 cases. It is a real
bug, and the first thing to fix after the gate.

At **6 cases**, all four failures are the detector, and every one of them is a
*single* agent (`owned: 1` twice, `owned: 2` twice) that missed the 10 ms bound:

```
[{23809, "peer"}] (owned: 2)
[{23826, "agent10573"}] (owned: 1)
[{23825, "agent6027"}] (owned: 1)
[{24497, "agent28099"}] (owned: 2)
```

The four failures are in four *different* test files (ReplyDebtTest,
AgentContextWarningTest, TurnAcceptanceTest, AgentsBatchTest), which is what a
systemic bound looks like: whichever test's teardown is unlucky loses. It is not
a property of any one test.

## The service-time curve

Per-call latency against 1..32 concurrent callers on one shared process. A
serialization point grows roughly linearly with callers; a pooled resource does
not. Full output in `notes/maxcases-ladder/*-service-time.log`.

| op | callers | vampire mean µs | celedyr mean µs | celedyr growth 1→32 |
|---|---|---|---|---|
| `GenServer.call` (one server) | 1 | 0.5 | 6.0 | |
| `GenServer.call` (one server) | 32 | 36.8 | 105.6 | 17.6× |
| `File.stat` (missing path) | 1 | 4.0 | 24.5 | |
| `File.stat` (missing path) | 32 | 155.9 | 574.4 | 23.4× |
| `File.rm_rf` (empty dir) | 1 | 67.1 | 267.7 | |
| `File.rm_rf` (empty dir) | 32 | 1311.4 | **6729.1** | **25.1×** |
| `File.rm_rf` (3 files) | 32 | 1998.6 | **8625.7** | **34.7×** |
| `Mimic.stub/3` | 1 | 2.2 | 13.3 | |
| `Mimic.stub/3` | 32 | 112.6 | 997.3 | 75× |
| `Mimic.allow/3` | 1 | 1.3 | 8.7 | |
| `Mimic.allow/3` | 32 | 36.8 | 232.3 | 26.7× |
| `Nest.Repo.query` | 1 | 48.6 | 395.7 | |
| `Nest.Repo.query` | 32 | 135.9 | 784.5 | **2.0×** |

Readings:

* **`Mimic.stub`/`allow` and `File.rm_rf` are serialization points.** Their
  latency grows ~linearly with callers (17–75× for 32× the callers). Postgres is
  **not** — 2.0× growth, i.e. pool-limited, so it is not what sets the ceiling.
* **`:file_server_2` is in the path, and that is measured, not inferred.** Tracing
  the file server's `:receive` during 200 operations: `File.stat` 200 messages,
  `mkdir_p`+`rm_rf` 1200, `GenServer.call` 0, `Postgres` 0.
* **celedyr is 4–16× slower per operation than vampire** across every op,
  including ones with no contention at all (`GenServer.call` at 1 caller: 0.5 vs
  6.0 µs). A topology-only rule cannot see this: both are ordinary multi-core
  x86 hosts.
* **`rm_rf` is the binding one for the teardown**, because `terminate/2` calls
  `TmpSpace.cleanup/2` → `File.rm_rf`, and the teardown stops owned agents
  sequentially. On celedyr a single `rm_rf` costs ~0.27 ms at 1 caller, ~1.4 ms
  at 8, ~2.7 ms at 16 and **~6.7 ms at 32** — so at realistic concurrency one
  agent's teardown alone consumes most of a 10 ms bound, and two exhaust it. That
  is the mechanism behind the detector failures above, and it is why raising
  `@stop_ms` would be treating a symptom.
* **The curve is a lower bound on the real service time.** It isolates one
  operation; the suite puts *every* file operation in every test through the same
  single file server, so the queue at a given `max_cases` is longer than the
  curve at that caller count suggests. This is the most likely reason the
  detector fires at 6 cases when the isolated numbers still look like they fit.

## Recommended `max_cases`

**vampire: 16.** `real_cpus/0` already returns 16 here and the ladder shows 0
failures at 16, 24 and 32 even at load 9–14; wall time at 16 (4.69 s) is
indistinguishable from its minimum at 24 (4.67 s). There is no measured reason to
go higher and no measured cost to staying here.

**celedyr: 2–4, and 4 only after the gate fix.** 2 cases is the only clean point
(0 failures); 4 has exactly one failure and it is not the detector. The mechanism
agrees: celedyr's file server is ~4× slower per call than vampire's and its queue
is shared with every other file operation in the suite, so the margin at 4 cases
is thin. `real_cpus/0` says 24 for this host, which is its worst measured point
(27 failures) — a 6× overshoot.

**This recommendation is provisional on the gate fix.** 13 of 13 failures at 12
cases and 19 of 27 at 24 are the teardown detector, and the gate is being
converted to a state-based check right now. If that lands, celedyr's ceiling
should move up materially and this table should be re-measured before anyone
hard-codes a number.

## What a rule would have to model (not a verdict)

The binding resource is not cores. On celedyr `real_cpus/0` = 24 = `nproc`, i.e.
one test per CPU and zero oversubscription, and it is the worst point measured.
What separates the hosts is the *service time of their shared single processes*
(`:file_server_2`, `Mimic.Server`) relative to the tightest legitimate bound in
the suite, and celedyr's is 4–16× worse at equal topology. Any rule that works
will need a measured latency term; two hosts cannot tell us whether topology
plus a constant would have been enough.

## Caveats

* celedyr shares its box with two libvirt VMs (`swan`, `goose` — the
  `qemu-system-x86_64` processes). They were not touched, and their load is part
  of celedyr's baseline.
* The vampire ladder ran at load 9–14 because another agent was working on this
  host; it is conservative for that reason, not quiet.
* `Mimic`'s curve covers stub/allow *registration*. If dispatch of a stubbed
  function also queues on the same server, the real load is higher than measured
  — unverified.

## The round-trip cost curve — and what the cited figure actually measures

Two phases, both `MIX_ENV=test mix run` on each host, so both run on the BEAM the
suite runs on. Scripts: `notes/maxcases-ladder/roundtrip.exs` (phase 1),
`notes/maxcases-ladder/roundtrip_os.exs` (phase 2).

**Phase 1 — load applied *inside* the BEAM.** N busy-loop BEAM processes, so the
independent variable is the BEAM's own run queue, read with
`:erlang.statistics(:run_queue)`. p50 per-call, µs:

| host | burners | run_queue | `gen_server_call` | `mimic_stub` | `postgres` |
|---|---|---|---|---|---|
| vampire (32 sched) | 0 | 0 | 2 | 3 | 36 |
| vampire | 64 | 33 | 45 | 46 | 382 |
| vampire | 128 | 97 | **184** | 183 | 794 |
| celedyr (24 sched) | 0 | 0 | 12 | 27 | 504 |
| celedyr | 16 | 2 | 95 | 87 | 354 |
| celedyr | 32 | 10 | 160 | 162 | 994 |
| celedyr | 64 | 42 | 414 | 417 | 1627 |
| celedyr | 128 | 106 | **585** | 587 | **3582** |

Round-trip latency **does** grow with run-queue depth — ~50× on celedyr from idle
to rq ~106 — it stays flat while the burner count is at or below the scheduler
count, celedyr's knee is at a *lower* queue depth than vampire's, and at equal
depth celedyr costs ~3× more. A two-process call and a Mimic call track each
other almost exactly, which is what "same shape, different server" looks like.

**Phase 2 — load applied *outside* the BEAM.** N OS burner processes
(`while :; do :; done`), which is the condition the repo's own figures use. The
actual burner count is recorded per row. p50 is **flat**: vampire
`gen_server_call` 1 µs at 0/8/16/32/48/64 burners (final loadavg 39.06); celedyr
12/12/8/8/8/10 µs at 0/8/16/32/48/64 (final loadavg 10.39). OS burners starve the
schedulers of CPU but do not deepen the BEAM run queue, and a two-process round
trip is unaffected; only `postgres_query` shows a tail (max 4–25 ms). So the two
phases are not the same experiment, and phase 1 is the one that moves latency.

**What the 926 ms figure measures — it is not a round trip.**
`test/support/sub_agent_tools_helpers.ex:37` sizes `@idle_fence_ms` from *a whole
sub-agent turn*: "a mocked LLM call, a real sub-agent spawn or peer delivery (DB
writes, a registry insert, a new process), and a second mocked LLM call" — p50
18.7 ms in-suite, and p50 926 ms / max 1534 ms under 48 burners (39 of 40 over
500 ms). The round-trip measurement in the same docstring (`@answer_ms`,
`notes/sketchy-slow-tests.md` §11) is **p50 21 µs / p99 84 µs / max 3.3 ms** over
473 reads at `max_cases: 16`, with no burners at all. That is consistent with the
curve above rather than in tension with it.

**Consequence for the ceiling.** At the deepest run queue I can produce (rq ~106
on celedyr) one round trip costs ~0.6 ms. The suite's tightest bounds are 250 ms
(the teardown's answer wait), 1000 ms (fences) and 3000 ms (per-test deadline);
reaching 250 ms would need roughly 400× that queue depth. So the round-trip term
is real, it is the right thing to bound, and it is *not* what is failing at 6–8
cases — the file-server term (1.4 ms per `rm_rf` at 8 callers, 6.7 ms at 32,
against a 10 ms bound) is still the one that lines up with those failures.

This is a measurement, not a verdict on the cause. It does not establish that
`file_server_2` is the cause either; it establishes that the round-trip figure
cited for the opposite conclusion measures a turn, not a round trip.

## Correction: the process is `file_server_2`

An earlier revision of this file said `:file_server`. On OTP 27 that name does not
exist — `Process.whereis(:file_server)` is `nil`, and the registered serializing
process is **`file_server_2`** (`Process.whereis(:file_server_2)` =
`#PID<0.53.0>`). The measurements above always traced `file_server_2`; only the
prose was loose. The framing is unchanged: a confirmed *location*, not an
established cause.
