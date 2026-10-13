# #21 — why 16 concurrent cases slow each other, measured

Branch `issue-21-contention` (base `e270e4f`). Host: 32 logical / 16 physical
CPUs (Ryzen AI Max+ 395); `max_cases: 16` (`Nest.Test.MaxCases.real_cpus/0`);
per-test deadline 3000 ms; fences 500/1000 ms.

**No production change was kept.** The authorised `partitions:` experiment was
run and **dropped** (numbers below). All probe/sampler scaffolding lived in
`/tmp/contention/` and was removed before committing; raw logs are in
`notes/test-runs/` (gitignored).

## Headline

On an idle host, **16-way concurrency does not miss a fence**: 8 clean runs
(seeds 1–8) plus 6 instrumented runs (seeds 1–6) = 14 × 2393 tests, **0 failures**.
The recorded "16 → 2, 24 → 12" (`notes/sketchy-slow-tests.md` §11, quoted in
`test/test_helper.exs`) was taken at a **2000 ms** deadline with **two other
agents running the suite concurrently** (§9: "load 6.9–10.5"), so it is not a
property of 16 cases per se.

Add **16 pure-CPU burner OS processes** — which touch nothing inside the BEAM —
and the recorded failure shape returns immediately: 3–13 failures per run, with
failures blocked in `Mimic.allow/3`, in `Nest.Agents.Supervisor.start_*`
(`supervisor.ex:107/151`) and in `:code_server.call/1`, exactly the traces
§2/§10b recorded. So the misses are **host CPU contention**; the BEAM-internal
queueing points decide *where* a starved test is standing when the deadline
expires.

## A. Registry partitions — refuted, and a regression

One-line `partitions: System.schedulers_online()` in `Registry.child_spec/0`.
Failure counts at `max_cases: 16`:

| condition | seeds | 1 partition | 32 partitions |
|---|---|---|---|
| idle | 1–8 / 1–4 | 0,0,0,0,0,0,0,0 | 0,0,0,0 |
| + 16 CPU burners | 1–5 | 5,6,8,10,6 (Σ35, mean 7.0) | 4,5,9,13,7 (Σ38, mean 7.6) |

The count does not move. Meanwhile the change **costs**: `Registry.select/2`
fans out over partitions, so the whole-registry `list_all/0` that every teardown
calls goes **21 ms → 485 ms** accumulated per run (p50 50 µs → 1 ms), and
`teardown_owned` 180 ms → 650 ms, `teardown_total` ~1.3 s → ~1.7 s. Dropped.

Why it cannot help: `Registry.register/3` writes its ETS tables *in the caller*
(no server round-trip — `lib/elixir/lib/registry.ex:1064`), `lookup/2` is a
direct ETS read, and the registry process's `message_queue_len` was **0 in every
one of ~2300 samples** across 11 runs. All three Registry functions together
cost **27 ms of a 4.5 s suite**.

## B. CPU or serialisation? (sampler every 20 ms)

| metric | idle (6 runs) | + 16 burners (5 runs) |
|---|---|---|
| run queue mean / p95 / p99 / max | 1.14–1.55 / 4–5 / 5–11 / 7–52 | 1.6–2.25 / 4–6 / 10–35 / **30–118** |
| samples with run queue > 32 | 0–0.5 % | 0–1.2 % |
| process count max | 809–833 | 802–840 |
| port count max | 47–48 | 47–48 |
| CPU busy (BEAM `utime+stime`, `/proc/self/stat`) | 67.9–70.2 cpu-s / 4.1–4.9 s = **14.5–16.6 cores** | 76–78 cpu-s / 7.7–8.3 s = **9.2–9.9 cores** |
| host steal | 0.0 s | 0.0 s |

Idle: the run queue is *tiny* while choke-point tails reach 100–500 ms — a
serialisation/descheduling signature, not oversubscription (never more than ~5
runnable processes). Loaded: the BEAM's CPU share drops ~40 % and its run queue
bursts past 32, so the inflation is starvation, not queue depth.

## C. The choke points, timed (call duration incl. queue wait)

Idle, seeds 1–6 (n = calls/run, Σ = accumulated ms/run):

| site | n | Σ ms | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| `Registry.lookup/2` | 2713 | 4.9–5.2 | 10 µs | 10 µs | 10 µs | 50 µs |
| `Registry.list_all/0` | 939 | 20–23 | 50 µs | 50 µs | 50 µs | 100 µs |
| `Agent.init/1` (inside the sup. critical section) | 545 | 1043–1381 | 1 ms | 2.5 ms | 25 ms | 100–500 ms |
| `DynamicSupervisor.start_child/2` | 541 | **2832–7771** | 2.5 ms | 25 ms | 50–500 ms | 50–500 ms |
| `Mimic.allow/3` (3 × per `start_agent`) | 377 | **3010–7627** | 50 µs | 25–100 ms | 250–500 ms | 250–500 ms |
| `Sandbox.allow/3` | 377 | 5.8–7.3 | 50 µs | 50 µs | 100–250 µs | 250–1000 µs |
| `teardown_total` (registry scan + DB + stops) | 939 | 1142–1860 | 250 µs | 0.5–1 ms | 2.5 ms | 500 ms |
| `ShellJobs.stop_all/1` | 545 | 15–21 | 50 µs | 50 µs | 250–1000 µs | 250–2500 µs |

Max `message_queue_len` sampled: **Registry 0**, ShellJobs 0–2,
`Mimic.Coordinator` 9–14, `DynamicSupervisor` 10–25, **`:code_server` 35–43**.

Under 16 burners the same sites inflate 2–10×: `Mimic.allow/3` Σ 4.0–11.1 s,
p90 50–100 ms, **p99 250 ms–2.5 s, max 2.5 s**; `start_child` Σ 5.4–8.2 s,
p50 5–10 ms, p99 100–250 ms; `Agent.init/1` p50 2.5 ms (2.5× idle). The
Registry does not move (Σ 5 ms lookups, 22 ms `list_all`, queue still 0).

## D. Where the loaded failures actually block (innermost relevant frame)

8 seeds × 16 burners per arm, `max_cases: 16`:

| arm | failures | `:code_server.call/1` | `Supervisor.start_*` | `Mimic.*` | other |
|---|---|---|---|---|---|
| baseline | 53 | **15** | **10** | 16 | 12 |
| app-wide module preload | 46 | **2** | **0** | **38** | 6 |
| 32 partitions (5 seeds) | 38 | 11 | 7 | 9 | 11 |

The code-server blocks are ordinary lazy **first-call** loads
(`error_handler.undefined_function/3 → :code.ensure_loaded/1 →
:code_server.call/1`), fired from inside `Nest.Persistence` and friends
throughout the suite — not just at start-up, because there are 485 modules and
the warm-up list cannot cover every path.

Preloading every module of the `:nest` app in `test_helper.exs` **eliminates**
the code-server and supervisor block sites (15+10 → 2+0) but does **not** reduce
the failure count (53 → 46, within the run-to-run spread of 3–13): the queue
simply moves to Mimic (16 → 38). The latency budget is conserved across the
BEAM's single-process rendezvous points.

*Note:* `mix test --preload-modules` is a **no-op** — `Mix.Tasks.Test` parses the
switch but only forwards it to `app.start` under `--slowest`
(`lib/mix/lib/mix/tasks/test.ex:572`). Preloading has to happen in
`test_helper.exs` (or via `mix do app.start --preload-modules, test`).

## Verdicts

| # | hypothesis | verdict |
|---|---|---|
| 1 | single-partition `Nest.Agents.Registry` | **REFUTED** — queue 0 in every sample, 10 µs lookups, 27 ms total; partitions move no failure count and cost 23× on `list_all` |
| 2 | one `DynamicSupervisor`, `init/1` inside its critical section | **SUPPORTED** — Σ 2.8 s idle / 5.4–8.2 s loaded, p99 50–250 ms, queue ≤ 25, and 10/53 loaded failure traces; 1.8–5.2 s of it is pure queue wait (`start_child` − `agent_init`) |
| 3 | global `ShellJobs.stop_all/1` | **REFUTED** — 545 calls, Σ 15–21 ms, queue ≤ 2, 0 failure traces |
| 4 | global `Mimic.Coordinator` | **SUPPORTED** — 3 calls per start, Σ 3.0–11.1 s, p90 25–100 ms, p99 250 ms–2.5 s, queue ≤ 14; 16/53 traces, and **38/46 once the code server is preloaded** — i.e. it is the last queue standing |
| 5 | code server | **SUPPORTED — the biggest single blocker** — queue 35–43 (deepest of any sampled process), 15/53 traces; removable by preloading, which then just moves the queue to Mimic |
| 6 | `bwrap` spawns | **not a bottleneck by these numbers** — ports ≤ 48, procs ≤ 840, `Sandbox.allow/3` Σ 6 ms, 0 traces; a large dirty-IO-scheduler CPU share is visible but no queue forms |

All loaded failures are `ExUnit.TimeoutError` (3000 ms per-test deadline)
blocked in the agent-start path — not bare fence misses (one run did show
`assert_receive {:chat_message, {:user, …}}, 1_000` firing first). Tests
> 500 ms: 22–26 idle (0.9–1.1 %) vs 28–35 loaded (1.2–1.5 %); > 1000 ms: 11–15
vs 19–22; > 2000 ms: 0–5 vs 5–7. The fence the ticket names
(`agent_user_message_mode_prefix_test.exs:69`, 500 ms) took **16–51 ms even
under load** — a 10–30× margin.

## What to fix

The Registry is not it. The latency lives at the BEAM's single-process rendezvous
points, and removing one only moves the queue to the next, so the fix has to
clear them all (or the host contention):

1. **Preload the app's modules** in `test_helper.exs`
   (`for mod <- Application.spec(:nest, :modules), do: Code.ensure_loaded(mod)`).
   Cheap, test-side, and it removes the code-server blocks (15 → 2 traces) and
   the supervisor blocks (10 → 0) outright. Do not rely on
   `mix test --preload-modules` — it does nothing without `--slowest`.
2. **`Mimic`** is then the only remaining queue (38/46 traces): 3 `Mimic.allow/3`
   calls per `start_agent/1`, each a `GenServer.call` to one global coordinator
   for 3 ETS operations, sharing that process with `Mimic.Module.replace!`
   (which recompiles the module) and `reset`. Make the private-mode `allow` path
   caller-side (`:ets.lookup(@table, :mode)` + insert) or fork Mimic.
3. **`DynamicSupervisor.start_child/2`** runs the child's `init/1` in the
   supervisor, so every start queues behind every other. `test_helper.exs`
   already warms the path; cutting the work per start (or the number of starts
   per test) is what is left.

If the goal is only "no misses at 16 on this host", nothing needs to change —
14 runs say it already holds. The comment in `test/test_helper.exs` should
record the conditions the 16 → 2 number was measured under (2000 ms deadline,
co-running suites at load 6.9–10.5) so it stops reading as a property of 16-way
concurrency.

## Reproducing

    # idle baseline (expect 0 failures)
    mix test --seed 1                     # 2393 tests, 0 failures
    # the load condition that fails
    (for i in $(seq 16); do yes >/dev/null & done); mix test --seed 1
    # then: 3-13 failures, blocked in code_server / supervisor / Mimic
