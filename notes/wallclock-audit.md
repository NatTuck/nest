# Wall-clock time as a synchronization primitive — audit and fixes

Scope: every place in `lib/` where time is used to *order* events or to wait for
a state to settle, rather than to bound an operation outside our control.
Method: every candidate enumerated with `rg` (`Process.sleep`, `:timer.sleep`,
`after `, `timeout`, `Task.await`, `GenServer.call`, `:sys.get_state`, `retry`,
`backoff`, `send_after`, `send_interval`, `monotonic_time`), then each one read
in context. Nothing here is taken from a comment or a list.

Line numbers are against `origin/main` at the time of the audit (`3f4c0ec`).

## The table

| file:line | what it waits for | internal/external | toxic? | mechanism fix | risk |
| --- | --- | --- | --- | --- | --- |
| `agents/agent/wait_for_idle.ex:174` (`min(wait_slice_ms(), remaining)`) | a peer agent's status, re-read from the space listing every 250 ms | internal | **yes** — the archetype: a poll for internal state | subscribe + monitor *before* the authoritative read; wake only on an idle status frame, a target `:DOWN`, the caller's `:DOWN`, or the deadline | **implemented** |
| `agents/agent/wait_for_idle.ex:53` (`@default_wait_ms`) | the caller's own declared bound | n/a | no | keep: the expiry is reported as an ordinary timeout result | — |
| `agents/agent/machine/stopping.ex:79,93` + `agent/config.ex:276` (`@stop_fallback_ms 2000`) | 2 s in `:stopping` before the turn's single terminal transition | internal | **yes** — a wall-clock settle window | see "Design decision 1" | **stopped** |
| `agents/agent/turn/executor.ex:153` (`send_after(… :stop_timer, ms)`) | the arm for the row above | internal | **yes** (same site) | see "Design decision 1" | **stopped** |
| `agents/agent/turn/executor.ex:514` (`after 5_000 -> exit(:no_worker_go)`) | the spawner's `{:worker_go, ref}` handshake | internal | no | keep: the ordering is established by construction (the go message); the expiry is reported as a worker crash | — |
| `agents/agent/turn/executor.ex:136` (`{:kill, pid}`) | "BEAM FIFO ordering guarantees the stop message is processed before the kill **when the worker is in BEAM code**" | internal | **yes** — an assumed order | see "Design decision 2" | **stopped** |
| `agents/agent/batch_coordinator.ex:234` (`after next_wait(plan)`) | a child agent's turn, per item | external (a child's turn) | no | keep: wakes exactly at the soonest deadline, never polls; the expiry is a slot marker | — |
| `agents/agent/batch_coordinator.ex:362,372` (`@call_timeout_ms`) | a `GenServer.call` into the parent | internal | no | keep: a defensive bound; the expiry is reported (a crash report or a swallowed `:ok`) | — |
| `agents/agent/batch_coordinator.ex` + `turn/executor.ex:262` (`Process.alive?` then `send`) | the coordinator being alive | internal | **yes** — a TOCTOU on liveness, documented as an accepted hole | see "Design decision 3" | **stopped** |
| `agents/agent/batch_plan.ex:55` (`@default_timeout_ms`) | the tool's declared per-item bound | external | no | keep: declared to the model, reported | — |
| `agents/agent/turn/give_up_delivery.ex:75,111` (`:sys.get_state/replace_state(pid, 1000)`) | a child's state, read synchronously before it is stopped | internal | borderline | keep, but see "Design decision 4": a synchronous read is a legitimate barrier; the expiry is reported as a lost debt by `terminate/2` | low |
| `agents/agent/turn/http_worker.ex:98` (`:sys.get_state/1`) | the agent's `cancelled` flag, on every stream event | internal | **yes**-adjacent | see "Design decision 5" | **stopped** |
| `agents/agent/tool_loop.ex:46` (`@spawn_request_timeout`) | a `GenServer.call` into the parent | internal | no | keep: defensive; the expiry is a tool error | — |
| `agents/agent/last_message.ex:23` (`@call_timeout`) | a `GenServer.call` into the caller | internal | no | keep: defensive; the expiry is a crash | — |
| `agents/agent/client_api.ex:86,107` (5 s) | watch register / fire | internal | no | keep: defensive | — |
| `agents/agent.ex:389,406` (`deliver_message/4`, `deliver_internal/4`, 5 s) | delivery into a peer's mailbox | internal | no | keep: defensive; the expiry is reported by the caller | — |
| `agents/agent.ex:423` (`stop_chat/2`, `:infinity`) | the whole stop | internal | no | keep: this *is* the stop barrier; unbounded by design | — |
| `sandbox/shell_jobs.ex:251` (`@kill_finalize_ms 5000`) | erlexec's `:DOWN` for a killed OS process | external | no | keep: bounds an external teardown; the expiry is a normal `{:killed, 137}` result | — |
| `sandbox/shell_jobs.ex:359` (`{:kill_timeout, 5000}`) | SIGTERM→SIGKILL escalation | external | no | keep: erlexec's own escalation | — |
| `sandbox/shell_jobs.ex:437` (`drop_agent`, no broadcast) | — | — | **yes** — a *missing* event | see "Gap 1" below | reported |
| `tools/shell_jobs.ex:158` (`after @kill_wait_ms`) | the internal `{:shell_job_exit, …}` driven by an external DOWN | external | borderline | keep: the consumer is order-independent (with/without the code) and the expiry is a normal result; the cost is latency only | low |
| `tools/shell_jobs.ex:132`, `agents/agent/watch.ex:235` (`after timeout`) | a background job's runtime | external | no | keep: the caller's declared bound, reported | — |
| `tools/shell_cmd.ex:144,178,225,463` (`after remaining_ms(deadline)`) | the sandboxed command | external | no | keep: the deadline on the command | — |
| `tools/shell_cmd.ex:213` (`after grace`) | whether a background command exited promptly | external | borderline | keep: both outcomes are honest results; it selects a *presentation*, not an ordering | low |
| `llm/http_worker.ex:37` (`@retry_opts`) | a transient transport failure | external | no | keep: retry/backoff on a genuinely external request | — |
| `llm/http_worker.ex:150` + both clients' `after state.watchdog` | the provider going silent mid-stream | external | no | keep: an idle deadline on the socket; reported as `{:stream_idle_timeout, ms}` | — |
| `llm/stream_consumer.ex:102` (`after 0`) | the worker's own mailbox | internal | no | keep: a non-blocking check; no elapsed time is involved | — |
| `models.ex:433` (`@default_deadline_ms 5000`) | auto-discovery HTTP | external | no | keep: bounds external I/O; the expiry is the scan's terminal broadcast | — |
| `sandbox/glob.ex:24`, `endpoint_probe.ex:29`, `llm/discover.ex:51`, `llm/client.ex:52`, `dot_config.ex:12` | an external command / HTTP probe / the provider | external | no | keep: all bound something outside our control | — |
| `_web/surgical_reloader.ex:78` (`@debounce_ms 100`) | coalescing external fsnotify events | external | no | keep: dev-only tooling, not production | — |
| `timeline.ex:389`, `persistence.ex:640` | — | — | no | wall-clock *timestamps*, not synchronization | — |
| `agents/agent/turn/executor.ex:60` (`send(self(), :iterate)`) | a mailbox deferral | internal | no | keep: deterministic, no elapsed time | — |
| `agents/agent/tool_loop.ex:539` (cast before `{:tool_results, …}`) | BEAM FIFO between one sender and one destination | internal | no | keep: the order *is* established by construction | — |

## Implemented: `WaitForIdle` (the poll slice)

`lib/nest/agents/agent/wait_for_idle.ex` polled the space listing every 250 ms to
notice that a peer had gone idle. Its moduledoc argued *for* that: the target's
own streaming traffic rides the same PubSub topic, so the wait could not be
bounded by received messages, and the listing re-read had to be the authority
because a status frame can be the transient `:idle` of issue #15.

Both of those arguments are about *what to trust*, not about *how to wake up*.
The poll was only ever needed because the wait subscribed to the targets'
topics **after** reading their status: an agent that went idle in that window
was never observed, and a 250 ms tick papered over the gap. It also covered a
target that vanished, which broadcasts nothing.

What changed:

* `subscribe/2` and the new `monitor_targets/2` run **before** the authoritative
  `partition/2` read. A disposition change before that read is visible to it; one
  after it is delivered as an event. There is no window left to paper over.
* the loop wakes on: a target's `{:chat_status, %{status: "idle"}}` frame; a
  target's `:DOWN` (the only event a stopped or archived agent produces — its
  topic is keyed by name and a process that is gone broadcasts nothing); the
  caller's `:DOWN`; or the deadline.
* `@wait_slice_ms` is gone. The only `receive ... after` value is the time left
  on the caller's own deadline — so a wake-up that is not an event *is* the
  expiry, and the expiry is still reported as an ordinary timeout result.
* the caller's own earlier read is still the reference for what `any` waits for
  ("a target that was busy when the call was made and is idle now").

**One behaviour change, and it is deliberate.** Everything else — the immediate
decision, and the partition the caller is handed — now comes from the
authoritative read rather than the caller's earlier one. On `main` the
immediate decision used the caller's read, so `all: true` could return
`Idle: bob, carol` while the fresh read had bob running; now it blocks until
every target is genuinely idle. That was a lie about a running target, so it is
a fix, not a regression, and it is pinned by *"the immediate decision is the
authoritative read's, not the caller's"* in `wait_for_idle_test.exs` (which
fails on `main`: the frames have the caller's read all-idle and the authority
read with bob running, and the test asserts the timeout partition, not
`Idle: bob, carol`). `any` is unaffected in the case that matters: with nothing
busy at the caller's read there is nothing to wait for, so it returns at once
with the fresh partition — which is honest even then, because the text it
reports comes from that read.
* `@max_after_ms` mirrors `ShellCmd`'s ceiling: `:timeout` has no upper limit but
  `after` does, so a wait longer than `after` accepts re-arms rather than
  reporting an expiry it has not reached. (Without the slice this would
  otherwise have become a new crash path for an absurd `timeout` argument.)

`lib/nest/agents/agent/watch.ex` keeps its own pre-read, deliberately. It is not
the authority — `await/6` re-reads after subscribing, and that read is what
decides — it is only the *reference* read that fixes which targets `any` is
waiting on. An earlier draft of this note claimed the pre-read was removed; that
was wrong, and the comment on the call site says why it is there.

Tests: `wait_for_idle_test.exs` and `watch_test.exs` are green. Four sites in
them had to stop relying on the poll (two in each file; see "Test findings"
below).

## Design decision 1 — the 2 s `:stop_timer` (not implemented)

`Machine.Stopping.do_stop/2` arms `Process.send_after(self(), :stop_timer, 2000)`
and that message owns the stop's single terminal transition to `:idle`. The
`:stopping` phase is a real phase with real semantics: late worker results are
dropped there, and `SubAgent.handle_spawn_request/3` refuses a batch
coordinator's spawn request there.

What the duration is *for* is not written down anywhere, and I could not find a
place where it is load-bearing:

* the spawn-request refusal does not depend on the duration. The request is in
  the parent's mailbox before the stop's own settle arms the timer, so mailbox
  order alone puts it ahead of `:stop_timer` — the code comment says exactly
  that ("mailbox order"). A 0 ms sentinel would keep that property.
* the late `{:worker_down, …}` for a killed worker is dropped in `:idle` too:
  the terminal transition goes through `Phase.rest/4` → `enter/4`, which clears
  `active_worker`, so `Failure.worker_down/3` sees an unowned pid.
* late `{:http_ok, …}` / `{:tool_results, …}` are `:ignore, :stale_result` in
  `:idle`; `do_stop/2` already clears `backgrounded`, so the backgrounded clause
  cannot claim them.
* `{:worker_started, …}` is killed by the catch-all clause in *any* phase.
* a coordinator's `:DOWN` is inert after the stop because `{:stop_all_children}`
  emptied the children map, so `Children.reporting_target?/2` is false.

So the 2000 ms is a "give the other process a moment to catch up" hedge. What is
load-bearing is that the terminal transition is *deferred to a sentinel* rather
than taken in the stop's own settle — and that is a design decision, not a
number:

1. **Sentinel with no delay.** `send_after(self(), :stop_timer, 0)` keeps the
   mailbox-order property and removes two seconds of latency. Risk: the sentinel
   goes through the timer service, so it is no longer *guaranteed* to be enqueued
   before a message a client sends immediately after `stop_chat/2` returns. That
   is what makes a test like `review-pr28`'s "a human message during `:stopping`
   is queued and then delivered by the stop's own drain" racy rather than
   deterministic — the message would sometimes arrive after the rest and start
   its own turn instead. Same end state, different mechanism and different status
   frames. **Do not do this without deciding which of the two shapes is the
   contract.**
2. **Immediate rest + an explicit record of what was killed.** Take the terminal
   transition in the stop's own settle, and make the spawn refusal
   order-independent: the stop already knows the coordinator pids it killed
   (`Children.reporting_targets/1`), so it can record them (a machine field, e.g.
   `refused_requesters`) and `handle_spawn_request/3` can refuse a request whose
   `task_pid` is in that record, whatever the phase. That is a new machine field,
   a new guard-test surface, and a changed ownership model for the "who may spawn
   for this parent" question — which is exactly the kind of thing the brief says
   to settle deliberately rather than patch. It also closes the `BatchCoordinator`
   "known residual" (a request that lands after the stop has finished is accepted
   today).
3. **Keep the window, document it as the contract.** Then say so: the stop is
   defined as "requests already in flight are refused; requests after the window
   are accepted", and the window's *length* is a policy knob rather than an
   accident.

My recommendation: 2, with the record cleared when the parent next rests to
`:idle` and re-established by each stop. It is the only option that removes the
wall clock instead of shortening it.

## Design decision 2 — `{:kill, pid}`'s FIFO claim (not implemented)

`Turn.Executor.execute({:kill, pid}, state)` sends `{:stop_chat, self()}` and then
`Process.exit(pid, :kill)`, with the comment "BEAM FIFO ordering guarantees the
stop message is processed before the kill when the worker is in BEAM code".

The qualifier is doing a lot of work. An exit signal is not a message: a process
that is blocked in a `receive` (which is where the shell-cmd worker spends its
life — `ShellCmd.collect_output/5`, and the SSE consumers) is killed at its next
scheduling point without ever matching the message it was sent. So the
`{:stop_chat, …}` cleanup path (`ShellCmd.handle_stop_chat/2`, which is what
actually stops the bwrap OS process) is reached only when the worker happens to
be between receives. When it is not, we fall back to erlexec's
`{:kill_timeout, 5000}` teardown — which the comment itself calls "fragile
(bwrap's PID namespace isolation can leave the inner command running)".

This is an *assumed order between two concurrently emitted signals*, which is
squarely in the brief. Two honest fixes:

* let the worker own its own teardown: send the stop and *do not* kill it
  immediately, with the kill as a bounded fallback (a deadline on the worker's
  own cleanup — legitimate, and the existing `:kill_timeout` machinery already
  bounds the OS side); or
* have the worker report its OS pid upward when it starts a command, so the
  agent can tear the OS process down directly and the BEAM process's death stops
  being load-bearing at all.

Both change who owns teardown, so: a design decision.

## Design decision 3 — `Process.alive?` then `send` (not implemented)

`Turn.Executor.execute({:child_message, …})` does `Process.alive?(target)` and
then `send(target, …)`; `BatchCoordinator`'s moduledoc already documents the
resulting hole ("an outcome already in this mailbox when the kill lands dies with
it, and the parent's delivery of an outcome races this process's death … so such
an outcome is dropped"). A liveness *read* is being used as if it were a
guarantee about a *later* send. The order-independent construction is to make the
delivery total: send unconditionally and let the target's absence be handled by
the sender's own bookkeeping (a monitor), rather than by a read that cannot be
atomic with the send. That is a changed ownership model for "who holds the
answers", so: a design decision, and the current degradation (fall back to the
parent's inbox) is already the right shape — it is the read that is wrong.

## Design decision 4 — `GiveUpDelivery`'s bounded `:sys` calls

`:sys.get_state(pid, 1000)` / `:sys.replace_state(pid, …, 1000)` before a child is
stopped. This is a *synchronous read of state*, not a wait for a state to settle,
so it is not the toxic pattern. The expiry is swallowed and the debt is reported
as lost by the child's `terminate/2`, which is a reported disposition. The one
thing worth a decision is the note in `BatchCoordinator.finish_failure/3`: each
call is bounded but the loop over pending children is not, so a stop can take
2 s per wedged child. That is a *cost* question (bounded work per item), not an
ordering one.

## Design decision 5 — the HTTP worker's `:sys.get_state` cancellation check

`Turn.HTTPWorker.check_should_stop?/1` is the `should_stop` callback
`LLM.Runner` consults between every stream event, and it is implemented as
`:sys.get_state(agent_pid)` — a synchronous round-trip into the agent — with
`GenServer`'s default 5 s bound, whose expiry is caught and read as "not
cancelled". Two problems, both wall-clock-shaped:

* the *decision* depends on elapsed time: an agent busy for more than 5 s (a
  stop, a synchronous child teardown, a slow settle) makes the worker decide the
  turn was not cancelled and keep streaming;
* it is a barrier on every delta, so the streaming worker synchronizes with the
  agent's mailbox per event.

`LLM.Runner`'s own docs say the mailbox path is the primary interrupt
(`StreamConsumer.stop_requested?/2`'s `{:stop_chat, from}` clause, which the SSE
consumers also match), and `Machine.Stopping.worker_kills/1` kills the worker
anyway — so in production this looks redundant with a mechanism that already
exists and needs no clock. Deciding to delete it means deciding whether the
cooperative path is a contract (it is the only interrupt a list-backed client
like `MockClient` has, and tests exercise it), so: a design decision. If it is
kept, the honest form is a message the worker can check non-blockingly (the same
shape `StreamConsumer` already implements with `after 0`) rather than a
cross-process state read with a timeout.

## Test findings — tests that were relying on the poll

Four sites in the wait tests were driving their scenario *with the poll* rather
than with an event, and had to change (two in each file). No assertion was weakened; each now drives
the real event, which is strictly stronger than waiting for a tick.

1. `test/nest/agents/agent/watch_test.exs` — "the target's delivery wakes the
   idle caller exactly once" and "a mid-turn caller fetches the queued delivery
   once". Both stubbed the listing with a `busy → busy → idle` FIFO and let the
   250 ms slice advance it, then asserted that the watch fired *satisfied*
   (i.e. the target's own delivery landed before the status frame). The ordering
   was an accident of the tick. They now emit the target's `chat:status` frame
   themselves (new `broadcast_idle/2` helper) after the delivery, so the ordering
   they assert is the ordering they set up, and the FIFO gains the frame the
   wait's own authoritative read now consumes.
2. `test/nest/agents/agent/wait_for_idle_test.exs` — "a busy target going idle
   reports the partition with no payload" and "all: true waits until every named
   target is idle". Their injected `{:chat_status, …}` message had become dead
   (the authoritative read already saw the frame that flipped the target), which
   would have left the tests asserting the right thing for the wrong reason. They
   now carry one extra snapshot so the injected event is genuinely what wakes the
   wait — the event path in blocking mode is exercised, not bypassed.

No test now fails because of a race that the fix exposed. (That is worth stating
plainly: the two ordering-sensitive watch tests are the closest thing, and they
were made *more* explicit rather than relaxed.)

## Gaps from the test-side audit (no event at all)

These are the same mandate seen from the other end: a poll exists because
production emits nothing at the moment that matters. Four confirmed.

### Gap 1 — `ShellJobs.drop_agent/2` notifies nobody (real production bug)

`lib/nest/sandbox/shell_jobs.ex:437`. The `{:DOWN, …}` handler for a dead agent
calls `drop_agent/2`, which stops each job's OS process, removes its script, drops
its entry, demonitors, and **drops `state.waiters` for those jobs without sending
anything**. `start`/`exit`/`kill` all `broadcast/2`; agent death does not.

Consequences, both real and not test-only:

* a `shell-wait` (blocking, or the async watcher) on a job whose agent dies waits
  out its whole timeout — up to the 300 s default — for a job that is already
  gone, and then reports "it is still running", which is false;
* the UI's job list stays stale until something else broadcasts.

Honest fix: a real notification, two of them.

* `drop_agent/2` broadcasts `{:shell_jobs, %{jobs: …}}` like every other state
  change (one line, and it is the same shape the UI already handles);
* each dropped job's waiters get an explicit message. The shape matters: reusing
  `{:shell_job_exit, id, code}` would be a lie (there is no exit code, and
  `ShellJobs.output/2` will return `{:error, :not_found}`), so it should be
  distinguishable — `{:shell_job_gone, id}` — and both consumers
  (`Tools.ShellJobs.blocking_wait/3` and `Watch.await_shell_job/4`) should word it
  as "the agent that owned this job is gone", not as an exit.

The `shell_jobs_test.exs:154` poll (`eventually(fn -> ShellJobs.list(key) == [] end)`)
then becomes `assert_receive {:shell_jobs, …}` / a `:sys.get_state` read after the
DOWN, and the *production* bug goes with it. This is the one gap I would fix
first: it is a behavior bug wearing a test-smell.

### Gap 2 — the batch coordinator is anonymous

`BatchCoordinator.start/3` (`lib/nest/agents/agent/batch_coordinator.ex:99`) starts
an unlinked task and returns the confirmation. The coordinator's pid reaches the
parent only through the `report_to:` option on its *first* child's spawn request
(`Machine.Children.register/4`), so between "the batch is launched" and "the first
child is spawned" the parent does not know the coordinator exists. Nothing
announces the coordinator's start; `batch_coordinator_test.exs:98` finds it by
scanning `Task.Supervisor.children/1` and reading each task's `$callers`
dictionary.

This is not only test observability: it is the mechanism behind the stop's
spawn-refusal window (Design decision 1) and behind `BatchCoordinator`'s own
"known residual". A coordinator that has not spawned yet is not a kill target for
a stop.

Honest fix: a real notification, and the natural sender is the coordinator itself
— its first act should be `GenServer.call(parent, {:coordinator_started, self()})`
(a call, so the parent's refusal for a `:stopping` parent arrives before the first
spawn attempt, and so the ordering is by construction rather than by window).
The parent records it as a reporting target (or in the record from Design
decision 1) and kills it on stop. Message shape: `{:coordinator_started, pid}`
with a `:ok` / `{:error, :stopping}` reply. That gives the test a deterministic
observable (the parent's state, read with `:sys.get_state/1`) and removes the
scan.

### Gap 3 — the timeline is written but never announced

`Timeline.record/4` (`lib/nest/timeline.ex`) appends one JSON line per event with
`File.write!/3, [:append]` — a *synchronous* write, one open/write/close per
event — and returns `:ok`. Nothing broadcasts. `timeline_emitters_test.exs:81` and
`:256` poll the file.

Worth separating two things:

* the write itself needs no barrier. It is synchronous and append-only, so once a
  line exists the transition that produced it has definitely happened, and the
  poll can never observe a torn or half-written state. The file is a *sound*
  observation.
* what the tests actually want is "the agent has reached state X", and the record
  is a proxy for it because nothing else reports it. The `worker_down` case is the
  clearest: the test has already seen `idle`, and the worker's DOWN lands *after*
  it, so there is no status frame to wait on — the transition is genuinely
  unobservable except through the record.

So: the poll is *defensible* here (unlike the others, it observes a synchronous,
monotone side effect), but it is still a poll, and the honest fix is a real
notification: when recording is on, `record/4` also broadcasts the line it just
wrote — `Phoenix.PubSub.broadcast(Nest.PubSub, "timeline:<run_id>", {:timeline, line_map})`.
Shape: the same flat map that went into the file (it is already bounded to 8192
bytes and already redacted), so the digest and a test see identical data.
Recording is off by default and off in production, so the cost is test-only in
practice. The alternative — keep the poll — should then be *documented* as
"waiting for a synchronous append that has no push channel", not left as folklore.

### Gap 4 — registry unregistration has no public notification

`Nest.Agents.Registry` is an Elixir `Registry` (`keys: :unique`). A dead process's
entry is removed by the partition server when it handles the link EXIT, which is
asynchronous with respect to both the death and any observer. So a read right
after `Process.exit(pid, :kill)` can still return the entry — the audit measured
639/2000 — and there is **no synchronous barrier available**: `Registry.lookup/2`
and friends read ETS directly, and every `Registry` mutation API keys on
`self()`, so no caller can force another process's entry out.

Sites that poll for it: `clone_agent_registration_test.exs:195`,
`clone_agent_chat_stop_test.exs:84,159,167`, `supervisor_spawn_test.exs:418`,
`supervisor_subagent_test.exs:341`, `give_up_delivery_test.exs:95`, and the
`assert_registry_misses/1` helper. Note the counter-example already in the tree:
`test/support/agent_test_lifecycle.ex:70` looks the pid up and then **monitors**
it, waiting for the DOWN — a read for discovery, a monitor for the barrier.

Honest recommendation, in two parts:

1. **The deterministic observable is the monitor.** A test (or code) that needs
   "this agent is gone" should `Process.monitor(pid)` and wait for the DOWN —
   including the `:noproc` DOWN a monitor on an already-dead pid delivers
   immediately. That is exact and needs no clock. The registry read stays what it
   is: a discovery read.
2. **"The name is free" is a different question, and the registry is not the
   authority for it.** The authority is the supervisor: `DynamicSupervisor.terminate_child/2`
   is synchronous and returns only once the child is gone (`Supervisor.restart_agent/2`
   already uses it for exactly this reason). `Supervisor.get_running_agent/2`
   additionally liveness-checks with `Process.alive?/1`, which is the closest
   thing to a synchronous authority the code has.

There is a **real production finding** hiding here:
`Supervisor.restart_agent/2` (`lib/nest/agents/supervisor.ex`) does
`DynamicSupervisor.terminate_child/2` and then `fetch_or_start_agent/2`, on the
documented assumption that "the Registry name is free before the restart". It is
not guaranteed: `start_under_supervisor/2` maps `{:error, {:already_started, pid}}`
to `{:ok, name}`, so a restart that races the partition server's cleanup reports
success while nothing is running. That is a wall-clock assumption in production
code, not just a test smell, and it is worth its own fix (verify the pid from
`:already_started` is alive, and treat a dead one as "the name is stale" rather
than as success).

## Contradictions with the brief

* The brief's legitimate category "a timeout whose expiry is reported as an error
  to the caller" covers most of what I left alone, but two sites sit between the
  categories and I have said so rather than forcing them: `ShellJobs`'s
  `@kill_finalize_ms` (the expiry is reported as a *normal* result) and
  `Tools.ShellJobs.await_killed`'s `@kill_wait_ms` (the expiry is a normal result,
  and the code is deliberately order-independent). Both bound an external process
  teardown, so I judge them legitimate — but the brief's wording would not have
  settled them on its own.
* `wait_for_idle.ex`'s moduledoc argued for the poll. The *code* needed to change,
  not only the comment: the moduledoc's two arguments (don't bound by message
  count; don't trust the payload) are both still true and are both preserved — the
  deadline is still the only bound, and `partition/2` is still the authority. What
  was wrong was the claim that a bounded `receive ... after` *slice* was the way to
  wait, when the real reason for the slice was a subscription taken too late.
* `lib/nest/tools/shell_cmd.ex:213`'s `grace_ms` window is a wall-clock *policy*
  choice (present an immediately-exiting background command as a foreground
  result) rather than a synchronization primitive. I left it, but it is the one
  remaining place where elapsed time selects which of two honest answers the
  caller gets, and a reviewer may reasonably want it named as such.

## Review round 1 — what changed, and what the review found

The first cut of the `WaitForIdle` change installed one monitor per target that
the *initial* read called busy, and nothing after that. The review found the
hole that leaves: a process that takes a target's name *after* that read is
never watched, and its death broadcasts nothing, so the wait would fall back to
the deadline — a narrowing relative to `main`'s 250 ms re-read, which is the one
thing this change must not do. (The reviewer also confirmed the read/subscribe
ordering argument itself against `phoenix_pubsub` and `Registry` internals.)

The fix, now in the code:

* monitors are a `%{pid => ref}` map, and `monitor_targets/3` adds one for every
  target with a live process, keyed by pid so a *replacement* process is
  monitored rather than mistaken for one already held. A `{:via, Registry, …}`
  tuple would not do: it resolves the name once, at monitor time.
* it runs on **every** read — the first one and each event-driven re-read — and
  it runs **before** the read, so the process the read is about is already
  watched whenever the read can see it. A name cannot be busy while the process
  answering for it goes unwatched: if the process changed, its predecessor's
  death delivered a `:DOWN` and its own start a status frame, so either way the
  next read re-runs this.
* the loop wakes on *any* target status frame, not only `idle`. A target that
  goes busy after the read is a target worth watching, and its own busy frame is
  the only notice that it is.
* the caller's deadline is still the only `receive ... after` value.

**Coverage, and why it needed a purpose-built test.** Every existing wait test
stubs the listing and names targets (`bob`, `carol`, `db-only`) with no process
registered under any of them, so `Registry.lookup` always missed and the monitor
code never ran. A test with a *real* agent as the target does not fix that: with
the real listing, the wait's own read reported the target **idle** while the
target was still alive and registered (`Process.alive?` true, `Registry.lookup`
`{:ok, pid}` on both sides of the wait, measured), so the wait fired on its first
check and the monitor was never involved. That observation is unexplained and
looks like a `Visibility`/registry artifact rather than anything this change
touches — it deserves its own look, because a listing read that reports a live
busy agent as idle is exactly the transient-idle class of bug the moduledoc
warns about. It is **not** fixed here and no test depends on it.

What the monitor is pinned by instead is a deterministic test
(*"a target's death wakes the wait when no frame can"*): a real process
registered under the target's name, a stubbed listing, and a stub that kills
that process on the read *after* the one that installs the monitor — so the
ordering is the wait's own read order, not a timer, and the only thing that can
wake it is the `:DOWN`. Verified: with `monitor_targets/3` stubbed out the test
fails; with it in place it passes. The real-agent variant was deleted rather
than left passing for the wrong reason.

## Precommit timing (recorded, not chased)

`scripts/precommit-test.sh` wraps `mix test` in `timeout 5`, and the suite
measured **7.2–7.7 s** on this host during the audit. That is not attributable
to this change: the reworked tests finish on an event the test broadcasts
instead of waiting out a tick, so the wait files went from 5.1 s to 0.9 s, and
the project's own note (`notes/faster-tests.md`) records 4.70–4.75 s on a quiet
host. Several agents were running suites against one shared Postgres at the
time. Recording it here so the next reader does not re-derive it, and not
touching the suite's total time in this change.
