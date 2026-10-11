# Plan: #36 — deliver a message through a blocking tool call

**Provenance.** Written from read-only reconnaissance at nest `dc3c93c` plus two focused
investigations (the trigger / event-action surface, and the test surface). Every `path:line`
anchor is from that HEAD; re-check before editing. Decisions were taken by the user in the
planning session — see "Decisions" for the rationale of each.

## Goal

A message arriving while the turn is in `:executing_tools` is delivered **immediately**: the
in-flight batch is backgrounded, the message lands in the transcript, and the batch's eventual
result re-enters as a message. No message is lost. No transient `idle`.

## Decisions

| # | decision | rationale |
|---|---|---|
| D1 | **Any** incoming message backgrounds the batch — human, peer `agents-send`, child completion | the issue's motivating case is a human message, but the W2 model is "every async result is an inbox message; nothing waits". Deferral to the turn boundary is unbounded once the shell-cmd cap is removed, so all kinds preempt. |
| D2 | The late result arrives as a `:notice`, worded like "your command finished" | `:notice` is the only honest kind (`Inbox.enqueue_internal/4` admits `:agent \| :user \| :query \| :notice`), and it already renders as "Runtime notice". |
| D3 | Background **only** when the tail has unanswered `tool_use` ids and a live worker | required for correctness, not convenience: the synthetic result must answer the pending ids. With none, `Repair.classify_live/2` classifies it `:stale` and drops it, and the following user append is `:invalid`. Also keeps the two fabricated-status tests green. |
| D4 | **No machine timer.** The bound lives in the promise: the synthetic result states the call's timeout | the tool's own timeout *is* the timer, and its expiry is an ordinary result. A system clock would either duplicate that or, if it killed anything, destroy legitimate long-running work. |
| D5 | A delivery that lands mid-batch reports `:delivered`, not `:queued` | the queue is an implementation detail the sender should not have to model. |
| D6 | `shell-cmd` gains a `timeout` argument, **default 60 s, no cap**, enforced as a **wall-clock** deadline | the model's declared timeout is the bound; no cap means it can ask for three days and get it. |
| D7 | **Stop means stop everything**: active worker + backgrounded workers + children/coordinators. Nothing beyond children | with messages now able to interrupt a turn, Stop's remaining job is "stop doing everything". |
| D8 | A backgrounded call killed by Stop produces an **append**, not an enqueue: a cancellation notice followed by a synthetic assistant confirmation | enqueuing would be drained by the stop path's own `:stop_timer` transition and start the very turn the human stopped. The append leaves the agent idle with the record in its history, visible on future turns. |

### Invariants that follow

1. **Every backgrounded call gets an answer** — by result, by death, by timeout, or by
   cancellation. No dangling promises.
2. **Nothing in the background path kills a worker, and nothing clears its entry** except
   Stop. A model-declared 3-day `shell-cmd` is legitimate; the system has no standing to
   second-guess it.
3. **The background path has no bound of its own.** The model's declared timeout is the bound;
   the system waits and delivers.

## Corrections to `notes/w2-plan.md`

1. **B.2's machine clause is unreachable as written.** `{:drain_inbox}` is an *action*;
   the event is `{:inbox_drain, entries, content}`, produced by `Executor.run_all([{:drain_inbox}])`
   (`turn/executor.ex:334-338`) and fed back through `Turn.settle/2`. Nothing emits it while in
   `:executing_tools` — `:iterate` falls to the catch-all `{:ignore, :not_applicable}`
   (`machine/transitions.ex:445`). **The trigger is the work; the clause is the easy half.**
2. **The `@live_phases` claim is backwards.** B.4 says the live bridge is "currently gated out
   by `MessageAppender.@live_phases`". `:executing_tools` is *in* that list
   (`message_appender.ex:69-78`), so the synthetic `[tool, ack, user]` append is already legal.
   What blocks #36 is the machine, not the appender.

## Steps

### Step 0 — `shell-cmd` wall-clock timeout (in this PR)

`collect_output/3` (`lib/nest/tools/shell_cmd.ex:398-411`) uses an **idle** timeout: every
stdout/stderr chunk recurses and re-arms the `after`, so a command that writes at least once
per interval never times out. `@default_timeout_ms` is not reachable from the model — the
schema (`lib/nest/tools.ex:184-209`) exposes only `command`, `background`,
`max_result_tokens`.

- Add a `timeout` argument: default 60, **no cap**, in seconds.
- Enforce a wall-clock deadline (compute once; pass `max(0, deadline - now)` into `after`).
- Tool description change is model-visible: it must land through the sanctioned rebuild points
  (init / workspace change / compaction — `tool_filter.ex:4-15`), never silently mid-session.
- **This step is load-bearing for D4**: without it a chatty backgrounded command never
  finishes and therefore never delivers anything.
- Test: a periodically-writing command is killed at the bound. Fails today.

### Step 1 — foundation (additive, no behaviour change)

- `Work.backgrounded: %{}` + type (`machine/work.ex`), and the field pin at
  `test/nest/agents/agent/machine_structure_test.exs:99-113`.
- New `MessageList` builders for the synthetic result and the confirmation. **Do not** overload
  the repair builders — four tests assert their wording (`append_pairing_bridge_test.exs:122-142`,
  `:40`, `:246`, `message_append_tags_test.exs:36`).
- Rewrite the two stale comments (`repair.ex:18-21`, `message_appender.ex:180-184`) without
  contradicting the behaviour they describe: `classify_live/2` still never fabricates a result;
  the machine does.

### Step 2 — late-result and worker-death routing (inert until step 3)

- A `{:tool_results, ref, results}` clause keyed on `work.backgrounded`, ordered **before** the
  stale clauses (`transitions.ex:190`, `:260`, `:366`).
- A `{:worker_down, pid, reason}` arm for backgrounded pids, ordered **before** the
  `active_worker` test (`transitions.ex:235-243`). Today such a `:DOWN` is
  `{:ignore, :unknown_worker_down}` — the entry is never pruned and no message is produced.
- One new action + executor clause: render the result, enqueue it as `:notice`
  (`Inbox.enqueue_internal/4`), clear the entry. Declared in `@actions`, spelled so the
  regex in `guard_test.exs:51-61` matches.
- Acceptance: exactly one delivery per backgrounded ref; an unknown ref is still stale-dropped
  (keeps `append_pairing_bridge_test.exs:473,490` and `machine_test.exs:130` green).

### Step 3 — the backgrounding transition + triggers (the risky step)

The `:executing_tools` + `{:inbox_drain, entries, content}` clause:

- move `{ref, pid, calls}` into `work.backgrounded` (necessary — `Phase.enter/4` nulls
  `worker_ref`/`active_worker`), reading the pending ids from `work.preflight.calls`;
- emit `[{:append_many, [synthetic, ack, user]}, {:consume_inbox, entries}, :iterate]`;
- `Phase.enter(m, :chat, :generating, :http)` — staying in `:executing_tools` would strand the
  turn, since `:iterate` is ignored there.

**Triggers.** External deliveries drain from the busy arm: `Inbox.handle_delivery/4`
(`inbox.ex:153`) and `Callbacks.chat_or_queue/4` (`callbacks.ex:84`) keep the enqueue +
broadcast, then call `Turn.drain_inbox/1` (the same function the idle arm uses). Internal ones
cannot: `Inbox.enqueue_internal/4` is called from the executor, and the drain decision for child
messages already lives in the machine — `child_event/2` (`transitions.ex:686-699`) drains only at
`:idle`, so it gains the `:executing_tools` arm. Add the predicate beside `busy_status?/1` so
"busy" keeps one definition.

**Traps these tests enforce:**

- The clause must be **total** with `preflight: nil`, `active_worker: nil`, `backgrounded: %{}`
  and an empty transcript — `machine_test.exs`'s transition-coverage runs
  `sample_event(:inbox_drain) = {:inbox_drain, [], "queued"}` against `state_at(:executing_tools)`
  (`machine_test.exs:643-663`). Do not read `work.preflight.calls` unguarded.
- The 500-step random property test (`machine_test.exs:443-462`) must never produce an invalid
  machine.
- `MessageAppender` **halts a batch on the first failure**, so `[synthetic, ack, user]` order is
  load-bearing: the synthetic result must be first and `:ok`.
- A **partial** synthetic result appends fine (`answers_any?`) and then fails the turn at the next
  `:iterate` via `:tool_pairing` (`transitions.ex:531-533`). If a stricter append-time check is
  wanted, that is new code + a new test.
- Appends run *after* `put_machine`, so at append time the phase is already `:generating`.

### Step 4 — Stop

- Build the backgrounded kill list **before** clearing the map (the pattern the stop clause
  already uses for coordinators, `transitions.ex:151-177`), sorted for determinism, and clear
  `backgrounded: %{}` in the same update. `machine_test.exs:152-186` asserts the exact
  `{:kill, …}` filter list — extend it deliberately.
- For each killed backgrounded call, **append** the cancellation notice + synthetic
  confirmation (D8). Not an inbox entry: the stop timer drains the inbox.
- Short design pass needed: the appender's terminal branch already fabricates an ack via
  `pairing_bridge/2` (`message_appender.ex:186-194`), so build the pair so we do not end up with
  two confirmations.
- Kills route through `{:kill, pid}`, which sends `{:stop_chat, self()}` before
  `Process.exit/2` — that handshake is what lets `shell-cmd` clean up its bwrap OS process
  (`shell_cmd.ex:421-439`).

### Step 5 — UI and wording

- `ToolResults.jsx` badges on `is_error` only, so with `is_error: false` a "still running"
  synthetic result renders as a **green "Success: shell-cmd" with a checkmark** — a transparency
  defect. Add a third state or make the wording unambiguous *and* fix the badge; add the case to
  `ToolResults.test.jsx:22-42`.
- `ChatTypingIndicator` / `getStatusLabel` will say "Generating response" while a batch still runs
  in the background. The transcript shows the synthetic result, so nothing is hidden — decide
  whether an explicit indicator is warranted.
- Confirm the late result's `InboxPanel` label (`:notice` → "Runtime notice").

## Test changes

Anything marked **Yes** in the "weakens?" column needs explicit user approval before it lands.
Everything else must end up strictly stronger: the existing anti-`idle`, ordering and index
assertions stay, and each gains the "the real result arrives later as a message" assertion.

| file:line | now pins | becomes | weakens? |
|---|---|---|---|
| `turn_acceptance_test.exs:399` (1.1.9) | a self-sent `agents-send` waits for the batch; counts 1→2→0; batch request does not carry them | the batch backgrounds itself on its own message; synthetic + ack + message land mid-batch; the real result arrives later | No |
| `turn_acceptance_test.exs:523` (1.1.10) | the human message sits in `live.inbox` while `:executing_tools` | delivered mid-batch; transcript gains synthetic + ack + `[mode: plan]…`; status leaves `:executing_tools` with no `idle` | No |
| `agent_channel_queued_message_test.exs:128` | the wire shows `pendingMessageCount: 2` after release | the human push is delivered mid-batch; the real result is queued later | No |
| `clone_agent_flow_test.exs:81` | the spawn confirmation *is* the transcript's tool result | the child's completion backgrounds; the confirmation arrives as a message | No |
| `sub_agent_test.exs:49,78,91,123,148` | the child's answer is queued while the parent is `:executing_tools` | **unchanged under D3** (the fixture has no live batch, so no backgrounding). Its *intent* is stale and should be reworded; a real-batch companion test should be added | No |
| `inbox_test.exs:371`, `agent_channel_queued_message_test.exs:26` | fabricated `:executing_tools` → the entry stays queued | **unchanged under D3** | No |
| `machine_structure_test.exs:99-113` | the `Work` field list | add `:backgrounded` | No |
| `machine_test.exs:152-186` | the exact `{:kill, …}` list on stop | extend with the backgrounded kills | No |
| `tool_loop_send_agent_test.exs:60`, `turn_acceptance_test.exs:515` | "Message queued for X (busy)" | "delivered" (D5) | No |
| `ToolResults.test.jsx:22-42` | green Success / red Error | add the "still running" case | No |

**New coverage required**

- The two-batch interleaving: batch A backgrounded, message 2 delivered, batch B spawned, A's
  result arrives **while B is in flight** — the only test that catches a mis-keyed
  `backgrounded` map or a `valid_ref?/2` that forgets to consult it.
- A self-messaging batch terminates rather than looping (the synthetic result counts as progress
  and resets `loop_count` via `progress_message?/1`, so this needs a real test).
- A backgrounded call that times out delivers its result.
- A Stop during a backgrounded call: the worker dies, and the transcript gains the notice +
  confirmation with **no new turn started**.
- The shell-cmd wall-clock deadline (step 0).

**Must keep passing unchanged:** the drain/queue machinery (`machine_boundary_delivery_test.exs`,
`turn/executor_test.exs`, `inbox_test.exs`), the transcript machinery
(`append_pairing_bridge_test.exs`, `message_append_tags_test.exs`, `wire_invariant_test.exs`,
`preflight_test.exs`), the debt/give-up suite, and the structural guards.

## Verification

Per step: `mix precommit` clean, read whole. Step 3 additionally needs a wire-validity check
(`Preflight` clean on the post-backgrounding transcript) and a **mutation check** on the headline
test — break the trigger and confirm the test fails, because a conversion like this is where a
vacuous pass hides.

## Not doing

- **Peer cancellation on Stop.** Stop stops children and coordinators, as it does today.
- **A background watchdog timer.** No second clock (D4). A tool whose own timeout is broken is
  silent — visible as an absent result in the timeline, not as a notice.
- Nothing in this plan changes `:erl_tar` or the size-cap mechanism; that discussion belongs to
  the inkfish sandbox thread, not here.

## Step 0 review outcome (adversarial review, 2026-10-10)

Verdict was **fix-first**. Both must-fixes are real and both are now being fixed in the same
change:

1. **A large `timeout` crashed the tool.** `receive … after N` raises `ErlangError:
   :timeout_value` for `N > 4_294_967_295` ms, and the whole remaining interval was passed to
   `after` on the first iteration — so any `timeout` ≥ 4 294 968 seconds (~49.7 days) raised, and
   `handle_timeout`/`:exec.stop` never ran, leaving the OS process unstoppable. Very reachable:
   the description promised "no upper limit", and a model that learned "timeout is milliseconds"
   from `agents-wait`/`agents-batch` passes `86400000` (one day in ms) → 8.64 × 10¹⁰ ms. Fixed by
   clamping the **check-in interval**, not the deadline, so "no cap" stays true.
2. **A stale `:DOWN` mis-delivered the next call's result.** `collect_output`'s `{:DOWN, _ref,
   :process, _pid, reason}` clause matched *any* process's `:DOWN`, and neither `handle_timeout/3`
   nor `handle_stop_chat/2` drained erlexec's `:DOWN`. A batch of two `shell-cmd` calls shares one
   tool worker, so the second call consumed the first's stale `:DOWN`: reproduced as `call-2`
   returning `{:ok, "[Command executed successfully with no output]"}` in ~5 ms while its own bwrap
   was still running. The clause predates step 0, but step 0 makes timeouts reachable and therefore
   makes this the common path — and **step 2 would have delivered that wrong result to the model as
   a runtime notice**. Fixed by threading erlexec's pid through `collect_output` and matching on it.

Also fixed in the same round: the one spuriously-failable timing assertion (replaced with an
observable-kill assertion plus a shorter command, which also cuts the regression-failure cost),
an explicit note in the description that this argument is in **seconds** while its siblings are in
milliseconds, the default derived from the constant instead of restated in prose, and the inherited
inaccuracy about `background: true` returning a handle immediately.

### Decisions recorded from the review

- **D4 concerns delivery, not the error flag.** A timed-out command's result stays an
  error-shaped result (exit code 1, `[Command timed out after Nms]` in stderr, `is_error: true`).
  Step 2's renderer must key off that **marker**, not the tuple shape, when wording the notice.
  Changing the flag is a separate decision with test fallout and is not part of this task.
- **`glob.ex`'s 30 s bound silently changed meaning** — it was an idle timeout and is now a
  wall-clock bound for `read`/`stat`/`glob` too. Intended; worth one line in the PR description.
- **A model-requested timeout now flows through `BatchSizer`'s error path**, which logs at error
  level on the premise that `is_error` is the rare path. Left as-is (pre-existing shape), but noted
  as noise to revisit.
- **The suite's real wall clock is 4.70–4.75 s against the wrapper's 5 s cap** — a ~5 % margin, not
  the ~1.1 s the ExUnit `Finished in` figure suggests. The review measured the same 4.70 s *without*
  the new tests, so this is pre-existing, not caused by step 0. It is a standing risk for every
  later step in this task: a busy host can miss the gate. See #21.
