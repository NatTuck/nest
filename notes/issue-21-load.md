# #21 goal 2 — the two levers, at 16 burners, measured

Branch `issue-21-load` (base `44fadc3`). Host: 32 logical / 16 physical CPUs
(Ryzen AI Max+ 395); `max_cases: 16`; per-test deadline **3000 ms, unchanged**.
The acceptance test for both levers is the burner arm: **16 `yes >/dev/null`
processes, `max_cases: 16`, 16 seeds, paired and interleaved** — each seed runs
both arms back to back, the design that made the preload's result in
`notes/issue-21-contention.md` trustworthy. Raw logs (every run, whole):
`notes/test-runs/issue-21-load/<tag>/` (gitignored).

Host load while the arms ran: 1-min loadavg 30–43 with the burners up (the 16
burners plus whatever else is on this box), so the *level* is above the note's
idle-conditioned runs; the arms are paired per seed, so the *difference* is what
is measured. Absolute level agrees with the note anyway: 8.3–8.6 failures/run in
the baselines vs 8.9 there.

## A. Sub-1000 ms fences → 1000 ms — NULL, reverted

The ticket's grep (`grep -rn "assert_reply" test/ | grep -E ", ?(500|750)\)?$"`)
**undercounts**. It finds only the sites whose timeout is on the same line as the
call: 20 `assert_reply` + 6 `assert_receive`. The real fence population at
500/750 is **62 sites in 18 files** — those 26, plus **36 whose timeout sits on
its own continuation line** (e.g. `test/nest/agents/agent_tools_test.exs:60`),
which is exactly what the `d6b2512` sweep missed for the same reason. All 62 were
raised to 1000 (nothing above 1000, and no non-fence bound touched: the nine
`:sys.get_state/…, 500` channel/reloader reads are the 500 ms §11 documents, and
`Eventually.eventually(…, timeout: 500)` ×2, `GenServer.call(…, 500)` ×1 and
`Watch.register_shell_call(…, 500)` ×1 are not fences).

| arm | Σ failures, 16 seeds | mean/run |
|---|---|---|
| 500/750 (base) | **137** | 8.56 |
| 1000 (raised) | **152** | 9.50 |

Paired: mean difference **+0.94 failures/run** (raised − base; sd 2.52,
t = +1.49, df 15, p ≈ 0.16); 3 seeds better / 10 worse / 3 tied. **Null**, and
if anything the wrong way.

It cannot be otherwise: **every** loaded failure in both arms is an
`ExUnit.TimeoutError` (the 3000 ms per-test deadline) blocked in the agent-start
path — `No message matching …` (a fence reporting itself) never appears in any of
the 32 logs. The blocking frames do not move either:

| innermost relevant frame | base (137) | raised (152) |
|---|---|---|
| `Mimic.allow/3` | 75 | 81 |
| `Mimic.Server.*` | 28 | 29 |
| `:code_server` | 18 | 26 |
| other | 16 | 16 |

Reverted, per instruction, and `SMELLS.md` ("any increase in a timeout is a
likely smell") is on the same side. **Not landed.**

## B. `Mimic.allow/3` — 95% of the calls were provably inert

**Probe** (temporary, `test_helper.exs` + `allow_mimic_stubs/1`; removed before
the commit). It traces `Mimic.allow/3` calls with `:erlang.trace_pattern/3` and,
for each one, asks whether the *calling* process has an ownership row for that
module: `:ets.member(Mimic.Coordinator, {caller_pid, module})`. That row is what
`Mimic.Server.register_owner/4` inserts for `stub`/`expect`/`reject`, and
`allow/3`'s own `handle_call` reads it (`{owner_pid, module}`) to resolve a
chained allowance — so a call whose row is absent cannot do anything: dispatch
resolves the owner, finds no stub for the mfa, and runs the original.

Idle, seed 1: **1209 `allow/3` calls per run**. 1131 of them are the
`allow_mimic_stubs/1` triple (377 agent starts × 3); the other 78 are the ~20
explicit sites in tests and turn helpers.

| module | useful (row present) | inert |
|---|---|---|
| `Nest.LLM.OpenAIClient` | 0 | 377 |
| `Req` | 0 | 377 |
| `Nest.DotConfig` | 5 | 377 |
| `Nest.LLM.MockClient` | 18 | 15 |
| `Nest.Agents` | 33 | 0 |
| `Nest.Models` | 2 | 5 |

**1151 of 1209 calls (95.2%) name a module the caller owns no stub for.** All
three triple modules are 377/377 inert — *every* `start_agent/1` in the run owns
none of the three — so the helper's own comment ("No-op for tests that don't use
Mimic") was not true of it: it made three global `GenServer.call`s to
`Mimic.Coordinator` per agent start, for nothing.

**Fix (landed).** `allow_mimic_stubs/1` filters on the ownership row before
calling `allow/3`, so it makes 78 calls/run instead of 1209 (−1131, −94%). The
*contract* does not change: a test that stubs one of the three before starting an
agent still gets its allowance (the guard is "does this test own a stub for this
module", which is the only condition under which the allowance can matter).
Nothing else calls `allow/3` for those three.

| arm | Σ failures, 16 seeds | mean/run |
|---|---|---|
| before (3 calls/start) | **133** | 8.31 |
| after (filtered) | **60** | 3.75 |

Paired: mean difference **−4.56 failures/run** (sd 3.56, **t = −5.13**, df 15,
p ≈ 0.0001); **14 seeds better / 1 worse / 1 tied** — **−54.9%**. Blocking frames:

| innermost relevant frame | before (133) | after (60) |
|---|---|---|
| `Mimic.allow/3` | 69 | **8** |
| `Mimic.Server.*` | 21 | **22** |
| `:code_server` | 25 | **12** |
| other | 18 | 18 |

The rendezvous really was cleared: `Mimic.allow/3` drops 69 → 8 and the count
falls with it. `Mimic.Server` (the per-scheduler shards, `{:stub, …}` /
`{:apply, …}`) is now the top blocker at 22/60 — i.e. the latency budget moved to
the next point, as the note predicted, but this time it did not refill.

## C. The fork — written up, **not** recommended on this evidence

A previous pass scoped the last step: make `Coordinator.allow/3` do its three
ETS operations in the caller, as `handle_call` already does, and delete the
handler. That is still the only way to take the remaining 78 calls off the
coordinator, and the patch is small:

```diff
   @spec allow(module, pid, pid) :: {:ok, module} | {:error, :global}
   def allow(module, owner_pid, allowed_pid) do
-    GenServer.call(__MODULE__, {:allow, module, owner_pid, allowed_pid}, @long_timeout)
+    case :ets.lookup(@table, :mode) do
+      [{:mode, :private}] ->
+        case :ets.lookup(@table, {owner_pid, module}) do
+          [{{^owner_pid, ^module}, actual_owner_pid}] ->
+            :ets.insert(@table, {{allowed_pid, module}, actual_owner_pid})
+
+          [] ->
+            :ets.insert(@table, {{allowed_pid, module}, owner_pid})
+        end
+
+        {:ok, module}
+
+      [{:mode, :global, _global_pid}] ->
+        {:error, :global}
+    end
   end
```
plus deleting `handle_call({:allow, …})` (`coordinator.ex:124-140`).

*What it costs:* a git dep in `mix.exs`/`mix.lock` (fork + rebase on every
upstream release, or an upstream PR to `edgurgel/mimic`), and `Mimic.allow/3`'s
caller-side version is our code from then on.

*What it would break:* only the serialization of `allow/3` against a mode flip.
A caller-side `allow` can insert a row while mode is `:global` (inert — in global
mode `allowed_pid/2` consults only the global pid) and can return `{:ok, module}`
where the serialized version returned `{:error, :global}` (Mimic's docs have
`allow` raise there). This suite never overlaps the two: ExUnit waits for **all**
async modules before running sync ones
(`lib/ex_unit/lib/ex_unit/runner.ex:118`), and the only global-mode module
(`test/nest/models_test.exs`) is sync. So no observable change here — but it is
a real semantic difference for a suite that does overlap them.

*Why it is not worth landing now:* the guard already took 1131 of the 1209 calls
(−94%) for four lines in a test helper and no dependency change, and what is left
(78 calls/run, 58 of them genuinely useful) is a small fraction of the remaining
failures — `Mimic.Server` is now the top frame, not `Mimic.allow/3`. If the
remaining 6% is ever wanted, the patch above is the whole change.

*The no-fork alternative* — the same three ETS ops written in `test/support/`
against `Mimic.Coordinator`'s public table — would remove the same 78 calls
without touching `mix.exs`, but it means owning a copy of a dependency's private
logic (table name and both row shapes), which is a maintenance decision of the
same kind. Not done.
