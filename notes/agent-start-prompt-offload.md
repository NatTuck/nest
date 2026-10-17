# Where the agent-start time goes

Why `Agent.init/1` is off the supervisor's critical section, and what the
measurements behind that are. Read this before moving anything else into (or
out of) `init/1`.

## The shape of the cost

`Nest.Agents.Supervisor` starts every agent with
`DynamicSupervisor.start_child/2`, which **blocks the single supervisor
process until the child's `init/1` returns**. So every agent start is
serialized against every other one, and anything expensive in `init/1` is
paid *serially* no matter how many tests (or callers) are running.

Instrumented full-suite run (`:counters` probes in `init/1` and
`build_state/2`, ~550 agent starts, 2872 tests, 5.5 s ExUnit):

| | summed |
| --- | --- |
| `init_total` | 3.64 s |
| `init_state` (`build_active_state/2`) | 3.36 s |
| `init_pipeline` (`build_vocation_pipeline/2`) | 3.11 s |
| `init_cc` (`Config.create_client_config/1`) | 0.25 s |
| `init_mounts` (`TmpSpace.create/3`) | 0.13 s |
| `init_tools` (`Tools.get_functions/2`) | 0.15 s |

Because the starts are serialized, that sum *is* the span the supervisor was
busy: ~3.6 s of a 5.5 s run.

`init_pipeline` is `SystemPrompt.compose_vocation_config/6`. Micro-benchmarked
in isolation (200 iterations, idle, `mix run`), it is **0.078 ms/call with no
workspace and 10.148 ms/call with one**, and the whole difference is
`agents_md_section/2` -> `Nest.Sandbox.read/3`, which shells `cat` through the
backend and forks a `bwrap` (7.8-10.2 ms/call). `ProjectConfig.section/1`,
`Mounts.resolve/2` and `Modes.catalog/2` are all ≤ 0.013 ms.

## What was changed

Prompt composition moved into the **caller** (`Init.prepare/1`), carried on the
attrs as `:prepared`, and reused by `PreSpawn.build_initial_system_message/1`
(for the persisted index-0 row) and by `build_state/2` (for the process). Both
`DynamicSupervisor.start_child/2` sites in `Nest.Agents.Supervisor` prepare
first, so `init/1` no longer composes under the supervisor's lock.

`prepare/1` is idempotent, is a no-op on attrs it cannot compose (so `init/1`'s
fallback still covers `start_supervised!({Agent, attrs})`), and **must only be
called on attrs `PreSpawn.put_mode/1` has already seen** — the mode decides the
caps the `AGENTS.md` read is authorized with, so preparing earlier composes the
persisted row under the wrong mode's caps.

A start still composes twice — once in `pre_spawn` for the row, once in the
supervisor for the process — because `pre_spawn/1` returns `{:ok, id}` and not
the attrs it derived, so `:prepared` does not reach the supervisor: a
caller-created agent's start re-reads its attrs from the row
(`Persistence.build_attrs_for_start/2`) and a spawn's start uses the spawner's.
Neither composition is under the supervisor's lock, which is the point.

Measured effect on the suite: ExUnit mean **5.6 s -> 5.27 s** (spread 5.1-5.5
across runs; the host is noisy, so use CPU — flat at ~88 s user — and treat a
single wall-clock number as ±0.3 s).

## The bigger prize, and why it is not taken

A/B on the same tree with the `AGENTS.md` read replaced by a host read
(behaviour preserved): **ExUnit 5.6/6.1 s -> 4.2 s, CPU flat (87.8 -> 85.2 user
s)**. So the remaining ~1.4 s is waiting on process spawns, not work.

It is not taken because two tests pin the read to the sandbox, and both are
right to:

* `test/nest/sandbox/shell_jobs_test.exs`'s sibling in
  `test/nest/agents/none_scratch_name_test.exs` asserts the prompt's
  composition stages its transcript (`<scratch>/.cmds`), which only happens if
  the read really runs a sandbox command;
* `test/nest/agents/supervisor_spawn_test.exs` asserts a `File.Error` that the
  sandbox read path raises.

So making `AGENTS.md` cheaper means deciding that this one read may skip the
sandbox — a transparency decision, not a performance tweak. `AGENTS.md`'s
sandbox rules ("do not add a host fast path") point the other way. The honest
options are a cached read keyed on the workspace with an invalidation rule, or
accepting the fork.

## A note on the fences

`ShellJobs.finish_job/3` removes the staged host script and *then* broadcasts
the job list, which is what makes that broadcast the happens-after event for
"the script is gone". `shell_jobs_test.exs`'s nested-tmp test once missed it
under `mix precommit`'s `--cover` run, and the cause was **not** load: the test
subscribed to the agent's PubSub topic *after* starting a job that exits in
about a millisecond, so the broadcast was published before the subscription
existed and is never replayed. It stayed invisible because
`ShellJobs.subscribe/3`'s late-subscribe clause still sends
`{:shell_job_exit, …}` for an already-exited job — the exit frame arrived and
only the frame below it hung.

Subscribe before the event. And where the wait is for the manager's *own* work
rather than for an external process, read the manager instead of using a clock:
`finish_job/3` and `drop_agent/3` each do their sends and their broadcast in one
callback, so a call to the manager returns after all of them have been sent.
