# Test-Suite Compile Cost

Why `mix test` spends most of its time compiling test files, what was
measured, and what was changed. Read this before adding anything clever
to a quoted test body.

## Where the time goes

Budget on the dev box (median of repeated runs, quiet machine):

| phase | wall | evidence |
| --- | --- | --- |
| mix startup + app boot | ~0.95s | `mix run -e ':ok'` 0.98-1.01s vs `--no-start` 0.35-0.37s |
| test-file load | ~2.0s | `mix test --only no_such_tag`: ExUnit reports 2.0s for 0 tests |
| test execution | ~1.7s | full ExUnit 3.7-4.0s minus the load |
| ExUnit sync/exit | ~0.1s | |
| **total** | **~4.7s** | |

The load phase is ~16.9s of single-threaded compile work squeezed into
~2.0s, so it is CPU-bound, not overhead-bound. `max_cases`, module
warm-up, `debug_info: false`, and swapping `require_file` for
`compile_file` were all measured and none of them help.

Parallel scaling on this box is the real ceiling: a pure-CPU workload
scales 12.1x at 32 workers, and 192 synthetic 200-line modules compile
only 3.9x faster in parallel than serially. So the load phase is close
to the practical floor for the CPU it must burn, and the only way to
cut it further is to compile less often.

## The pathology: a bare `rescue` in a quoted test body

`Nest.TestSupport.AgentTestMacro` replaces `test` for every module that
uses `Nest.DataCase` / `NestWeb.ChannelCase` (88 of 192 test files; 747 of the
1892 `test "` declarations, a grep count — ExUnit reports 1907 once generated
tests are counted). Whatever it quotes is compiled into *every* test body.

Per-test compile cost, 400 synthetic trivial tests per variant. These are
*ratios* from one harness, not absolute costs: the numbers move with the body
used, and an independent re-measurement on the same box reproduced the gap
between the shapes while landing at slightly different absolutes (6.21ms/test
for the `rescue` variant against the 5.73ms below). What the fix removed is that
gap, which is what the A/B measurements further down confirm without relying on
this table.

The arithmetic that ties this table to the suite: 747 tests x ~5.7ms is ~4.3s of
*serial* CPU, and the parallel test-file load runs at roughly 12x effective on
this box, so the table predicts ~0.35s of wall clock — which is what the
interleaved A/B measured. Nothing here implies a 4s wall-clock win.

| test body shape | ms/test |
| --- | --- |
| plain `ExUnit.Case` test | 0.44 |
| + `import Ecto`, `Ecto.Changeset`, `Ecto.Query`, `Nest.DataCase` | 0.44 (free) |
| `try/catch` + `__STACKTRACE__`, nothing else | 0.80 |
| `try/rescue` only | 3.25 |
| `try/rescue` + `__STACKTRACE__` | 3.16 |
| `try/rescue/catch` + `case` + two raise calls (old wrapper) | **5.73** |

A bare `rescue` clause costs ~2.7ms of compile time per test and buys
almost nothing: `catch kind, reason` already catches `:error`. The only
difference is the *form* of the re-raised reason — `rescue` binds
`Exception.normalize/3`, so an Erlang reason came back as
`%ArithmeticError{}` instead of `:badarith` — and ExUnit normalizes it
for display either way, so failure output is byte-identical.
`__STACKTRACE__` is free, and `catch` is nearly free.

## The fix

`wrap/1` is now a single inline `try/catch/else`, and the failing path
delegates to `Nest.Agents.AgentTestLifecycle.reraise_after_teardown/3`.
`try/else` matters: the success path is not protected by the `catch`, so
a failing `assert_zero_remaining!` propagates directly and cleanup can
never mask it. `:erlang.raise/3` re-raises `:throw`/`:exit` too, with the
original stacktrace — `reraise/2` only handles `:error`.

Why the `catch` stays (and why we did not simply let the body's exception
propagate): the teardown must run in the test process, because
`stop_test_agents/0` discovers owned agents with a DB query and the test
pid is the sandbox owner. `on_exit` runs after that process is gone, and
the failure path is exactly when an agent is most likely still in flight
(a test that failed on a timeout is a test whose agent never went idle).
Agents trap exits (`Nest.Agents.Agent.init/1`), so a dying test process
does not stop them synchronously.

Measured effect:

| | before | after |
| --- | --- | --- |
| serial compile of the 88 case-template files | 15850ms | 12649ms |
| parallel load of all 192 files (32 workers) | 2512-2608ms | 2155-2176ms |
| `mix test` wall, interleaved A/B, 3 rounds each | 4.88/4.96/5.16s | 4.83/4.68/4.71s |

Failure reports are byte-identical before and after, including the
single-frame stacktrace: `__STACKTRACE__` is re-raised unchanged, so no
catcher frames are added, and ExUnit's `prune_stacktrace/1` cuts the
trace at the first `ExUnit.Runner` frame either way.

## Other findings

- **`erlexec` costs a fixed 350ms at every app boot.**
  `deps/erlexec/src/exec.erl` `init/1` opens its port program and then
  `receive ... after 350` as a liveness check; the port starts fine, so
  the full 350ms is always paid. `Port.open` on the binary itself is 0ms,
  and the rest of `Nest.Application`'s supervision tree totals 62ms.
- **`mix test --no-compile` changes nothing** (2.79-3.03s vs 2.91-3.01s
  for a zero-test run), so the compile check is not worth attacking.
- `ExUnit.Case.register_test/6` writes module attributes and
  `__before_compile__` emits `ExUnit.Server.add_module/2` into the module
  body, so a precompiled `.beam` would not register itself with the
  runner. Caching compiled test files is therefore a loader project, not
  a compile-flag project.
