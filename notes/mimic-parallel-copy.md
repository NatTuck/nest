# Copying Mimic's modules from the caller, in parallel, at boot

Branch: `issue-21-parallel-copy` (off `issue-21` @ `824d376`). NOT reviewed, NOT merged.

## The problem

Under plain `mix test` (no `--cover`), `Mimic.copy/1` only *marks* a module. The copy
itself is done by the first line of `Mimic.Server.stub/expect/reject`,
`Coordinator.ensure_copied/1`, and `Mimic.Coordinator` performs it inside its own
`handle_call`:

    handle_call({:ensure_copied, module}, ...)          coordinator.ex
      -> ensure_module_copied(module, state)
        -> Mimic.Module.replace!(module, state.modules_opts[module])

`replace!/2` recompiles the renamed original and then compiles a whole mock module, so
each copy is two compiler invocations. A GenServer serialises its `handle_call`s, so
all 18 copies are serialised against each other, and they are paid *during* the suite.

## The control: the Coordinator API cannot be parallelised

`/tmp/damaged-cheetah/mimic_copy_probe.exs` marks the 18 modules the way
`Mimic.copy/1` does and then copies them three ways. Run as
`MIX_ENV=test NEST_MIMIC_PROBE=<mode> mix run <script>` from the project root.

| mode | vampire (32 sched) | celedyr (24 sched) |
|---|---|---|
| `Coordinator.ensure_copied/1`, serial | 712 ms | 3024 / 2986 ms |
| `Coordinator.ensure_copied/1`, from 24-32 concurrent tasks | **716 ms** | **2908 / 2988 ms** |
| `Mimic.Module.replace!/2`, from the caller via `Task.async_stream` | **135 / 124 ms** | **457 / 499 ms** |

The middle row is the point: throwing 32 concurrent callers at the Coordinator buys
nothing, because they all queue behind the one `handle_call` doing the compile. The
speed-up only appears when the work is driven from the caller. In every mode all 18
modules ended up `Mimic.Module.copied?/1` and `Mimic.stub(Req, :get!, ...)` actually
intercepted `Req.get!(:probe)`, so the caller-side copies produce working mocks.

`Code.compiler_options/1` is global (verified: a value set in one process is visible in
a `Task`), and `replace!/2` toggles `ignore_module_conflict` around `create_mock/2`. That
toggle guards a *warning*, not an error -- re-creating an already-loaded module warns
("redefining module X") rather than raising, and 18 concurrent `replace!`-shaped calls
produced 0 errors and 0 warnings. So the caller-side route is not unsafe for that reason;
it is kept honest by the `copied?` guard below instead.

## Inside a real suite boot

`NEST_MIMIC_COPY_TIMING=1` prints the block's cost:

| host | run | cost | `already_copied` |
|---|---|---|---|
| vampire | plain | 126 ms | 0/18 |
| celedyr | plain | 494 / 499 / 517 ms | 0/18 |
| celedyr | `--cover` | 190 ms | **15/18** |

The cover row is why the `copied?` guard exists. Under `--cover`, `Cover.enabled_for?/1`
is true for the 15 *project* modules, so `Mimic.copy/1` has already copied them inside
the Coordinator and recorded the coverdata path in its `modules_beam` map that `reset/1`
restores. The guard skips those 15, so the cover path is untouched. The 3 that are left
are `Req`, `Phoenix.Channel` and `Task.Supervisor` -- dependencies, which `mix test
--cover` does not cover-compile, so they have no coverdata to lose.

## celedyr, pass 1 -- interleaved off/parallel/off/parallel

Load average climbed monotonically across this pass (2.64 -> 12.75), so the second run of
each pair was always the more loaded one. Failure counts survive that; wall and body do
not.

| arm | wall ms | body | failures | of which Mimic | copy ms | load before |
|---|---|---|---|---|---|---|
| off | 18523 | 14.6 s | 18 | 13 | 0 | 2.64 |
| parallel | 19891 | 15.3 s | 5 | 0 | 494 | 6.92 |
| off | 19408 | 15.5 s | 21 | 17 | 0 | 9.59 |
| parallel | 20451 | 15.9 s | 7 | 1 | 509 | 11.74 |

## celedyr, pass 2 -- balanced order off/parallel/parallel/off, 60 s settle

This pass exists because pass 1's drift is monotonic. Loads are matched.

| arm | wall ms | body | failures | of which Mimic | copy ms | load before |
|---|---|---|---|---|---|---|
| off | 18638 | 14.6 s | 15 | 14 | 0 | 2.51 |
| parallel | 19153 | 14.6 s | 4 | 0 | 494 | 2.44 |
| parallel | 19399 | 14.9 s | 3 | 0 | 499 | 2.82 |
| off | 18504 | 14.6 s | 19 | 15 | 0 | 2.34 |

Across all eight celedyr runs: **lazy 59 Mimic failures of 73; parallel 1 of 19.**

## What this does and does not buy

* **It removes the Mimic failure class.** On celedyr that is 81% of all failures. This is
  the whole win, and it is robust -- in every pair the parallel arm had fewer failures
  while being the *more* loaded one (pass 1) or equally loaded (pass 2).
* **It does not shorten the suite.** The body is 14.6 s in both arms. The copies were
  never a throughput cost on celedyr -- they are a *latency* hazard: the Coordinator
  spends up to 3 s compiling, and any test that needs to register a stub in that window
  blocks. Moving the work to boot removes the hazard without changing the total.
* **Its price is the copy block itself**, ~0.5 s on celedyr and ~0.13 s on vampire, where
  the same block serial costs ~0.7 s. So on vampire this turns the eager copy from a
  ~+0.4 s cost against the 5 s gate into a ~+0.13 s one.

## Coverage

`mix test --cover` gives `[TOTAL] 87.4%` in **both** arms (`coveralls.json` requires
`minimum_coverage: 85`). Unchanged.

## Caveats

* These runs use the default `max_cases` (`Nest.Test.MaxCases.real_cpus()` = 12 on
  celedyr). The earlier celedyr baseline (lazy 7/3/3 failures -> serial-eager 1/2/1) was
  taken at `--max-cases 8`, so absolute failure counts are not directly comparable across
  the two; the direction, and the Mimic/non-Mimic split, are.
* Residual non-Mimic failures remain (3-7 per run): `Nest.Credo.Check.NoDrainLoopsTest`,
  `NestWeb.LobbyChannel*`, `NestWeb.PageControllerTest`, `NestWeb.SurgicalReloaderTest`,
  `NestWeb.AgentChannel*`. That is a separate problem from this one.
* `reply_debt_test.exs:315` (`Supervisor.get_running_agent` racing the archive) appears
  in both arms on both hosts. It is not Mimic-related and this change does not touch it.
