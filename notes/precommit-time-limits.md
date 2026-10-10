# Precommit time limits — the four buckets

`mix precommit` runs the Elixir suite **exactly once**, under coverage, via
`scripts/precommit-test.sh`. That one run is measured as four phases, each with
its own budget.

| bucket | contains | vampire | other hosts (x3) |
| --- | --- | --- | --- |
| **setup** | everything before ExUnit starts: mix boot, `ecto.create`, `ecto.migrate`, cover instrumentation, app boot | <= 4 s | <= 12 s |
| **load** | test-file compile/require (ExUnit's "Finished compilation cycle of N modules" step) | <= 4 s | <= 12 s |
| **run** | the tests themselves | <= 3 s | <= 9 s |
| **post** | after ExUnit's summary: cover analyse/export/report, teardown | <= 3 s | <= 9 s |

The buckets exist so that a regression **names the phase it moved**. They are
not a target to optimise against; all four pass with margin today.

## Measured baseline

Idle, covered, full suite, ~7.3 s wall:

| bucket | baseline |
| --- | --- |
| setup | ~2.8 s |
| load | ~2.5 s |
| run | ~1.0 s |
| post | ~1.2 s |

## How the numbers are produced

`test/support/test_timing.ex` (`Nest.TestTiming`) is an ExUnit formatter that
runs alongside `ExUnit.CLIFormatter` and prints one line:

```
NEST_TEST_TIMING setup_ms=.. load_ms=.. run_ms=.. reported_ms=..
```

- **setup** = `suite_started` minus a wall-clock `T0` the script puts in
  `NEST_TEST_T0_US`, because the formatter cannot see anything that happened
  before it started.
- **load** = `suite_started` to the first test/module event. Valid because Mix
  calls `ExUnit.async_run/0` *before* it requires the test files.
- **run** = ExUnit's own `run` time minus `load`. ExUnit's `run` field already
  contains the load (its `start_time` predates the requires and its `load` field
  is `nil` under `mix test`), and `reported_ms` is exactly the "Finished in X
  seconds" number.
- **post** = `wall - (setup + load + run)`, computed by the script.

A phase that cannot be computed is emitted as `-1`, and the script **fails
loudly** rather than passing.

## How to read a failure

```
precommit-test: BUDGET FAILED
load 4.3s (budget 4.0s)
```

The bucket is named with its actual and budgeted value. Exit codes:

| code | meaning |
| --- | --- |
| 0 | ok |
| 1 | coverage shortfall (ExCoveralls / `coveralls.json`) |
| 2 | test failures (ExUnit's own code) |
| 3 | a timing bucket blew its budget, or the timing line was missing |
| 124 | the hang-guard fired |

If more than one applies the loudest wins: `124 > 3 > 2 > 1 > 0`. Every problem
found is printed, so nothing hides behind the exit code.

The hard `timeout` in the script is a **hang-guard only**, set at 2x the sum of
the four budgets (28 s on vampire). A normal overrun is measured and reported,
never SIGTERM'd — the old `timeout 5 mix test` could not say which phase ran
long, and a green run killed during teardown read as a failure.

The full captured output of every run is written to
`notes/test-runs/precommit-test.log` (gitignored).

## The x3 rule

Every budget is multiplied by 3 on any host that is not `vampire`, because
`vampire` is the fast reference box. `PRECOMMIT_TEST_HOST` overrides the
hostname lookup so the off-host branch can be exercised on `vampire`.

## Hooks for testing the gate itself

Not for use in precommit:

- `PRECOMMIT_TEST_HOST=vampire|other`
- `PRECOMMIT_TEST_ARGS="test/some_test.exs"` — extra args for `mix test`
- `PRECOMMIT_SETUP_BUDGET_MS`, `PRECOMMIT_LOAD_BUDGET_MS`,
  `PRECOMMIT_RUN_BUDGET_MS`, `PRECOMMIT_POST_BUDGET_MS`

## History

Older notes and comments that say the suite "must take less than 5 seconds" are
**history**. That single 5 s `timeout 5 mix test` gate was replaced because it
could not attribute a slow run to a phase, and because a run that finished green
but was killed during teardown was indistinguishable from a real failure. The
budgets above supersede it. Do not confuse them with ExUnit's *per-test* timeout,
which is also 5 seconds.
