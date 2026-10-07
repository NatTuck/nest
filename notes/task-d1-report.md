# Task D1 report — server half of human messages during a turn (issue #15, second half)

Branch `boundary-delivery`, on top of task C (`703bad5`). Scope: the server
(`lib/` + Elixir tests). `assets/**` (task D2's browser half) untouched.

## (a) Files changed

### Production (`lib/`)

| file | change |
| --- | --- |
| `lib/nest/agents/agent/inbox.ex` | Entry is now `%{from, content, timestamp, kind, mode}` (`kind: :agent \| :user`, `content` verbatim, `mode` the human's request). `handle_delivery/3` records `kind: :agent, mode: nil` (behaviour otherwise unchanged: idle → drain, busy → queue, broken → error, cap → error). New documented `enqueue_user_message/4` for the human path (never refuses; the cap bounds runaway *agent* producers only), `busy_status?/1` (one shared definition of "busy"), `drain_mode/1` (the one-mode rule), `serialize/1` now emits `"kind"` + `"mode"` beside the existing keys, `combine/1` labels by kind (`[Message from agent "<from>"]` / `[Message from the user "<from>"]`, bare label for a nil sender), and the over-cap pointer text no longer claims "from another agent". Moduledoc documents both producers, the disposition, the delivery, and the one-mode rule. |
| `lib/nest/agents/agent/callbacks.ex` | `chat_or_drop/3` → `chat_or_queue/4`; the two old cast clauses replaced by one 4-tuple clause. `:idle` → `ChatPipeline.handle_chat/3` (mode applies now); a busy status → `Inbox.enqueue_user_message/4` (no drop, no rejection); a broken status → drop (the channel already reported `agent_status_<status>`, no new logging). Comment states this is the atomic authority (runs in the agent process) and the channel's read is UX only. |
| `lib/nest/agents/agent.ex` | `chat(pid, content, mode \\ nil, sender \\ nil)` casting `{:chat, content, mode, sender}`; `:ok` contract unchanged for 2–3 arg callers; doc explains `sender` and the queue-while-busy behaviour. |
| `lib/nest/agents.ex` | `chat(space_id, name, content, mode \\ nil, sender \\ nil)`; threads `sender` to `Agent.chat/4`. |
| `lib/nest/agents/agent/turn/executor.ex` | `execute({:drain_inbox}, …)` applies the batch's mode to `state.live.mode` (new `applied_mode/2` = `Inbox.drain_mode(entries) \|\| state.live.mode`) before emitting `{:inbox_drain, entries, content}`, with a comment on why it is applied here and never at enqueue time (`ctx.mode`/`ctx.caps` are rebuilt every settle). |
| `lib/nest_web/channels/agent_channel.ex` | `chat:message` no longer rejects `:streaming`/`:executing_tools` (they queue) and `:compacting` moved out of the rejected list; the rejected set is now `@broken_statuses Machine.blocked_phases()` (the same five statuses as specified, from the machine's declared vocabulary); passes `socket.assigns.current_user.username` as the sender; comment says the channel's status read is UX only and the agent's read in `chat_or_queue/4` is the authority. |
| `lib/nest/agents/agent/chat_state.ex` | `inbox` field doc + struct comment: two kinds, the entry shape, the verbatim content, and the drain now attributed to the turn executor (also fixes `review-c` F8). |
| `lib/nest/agents/agent/init/needs_repair.ex` | Moduledoc reference `Callbacks.chat_or_drop/3` → `chat_or_queue/4` (the channel still refuses `chat:message`). |

### Tests

| file | change |
| --- | --- |
| `test/nest/agents/agent/inbox_test.exs` | New "entry shape and serialization" describe (`serialize/1` for both kinds + nil sender/mode; `combine_and_offload/2` labels both kinds and drops an unknown sender; `drain_mode/1` picks the most recent human mode and ignores agent entries/nils) and "human chat messages" describe (busy `:streaming`/`:executing_tools`/`:compacting` queue with sender+mode and start no turn; idle starts the turn immediately in the requested mode; every `Machine.blocked_phases()` status drops and queues nothing; the drain applies the most recent human mode and otherwise leaves the mode alone, asserting the delivered `[mode: …]` prefix; an over-cap *human* message is offloaded to a scratch file and delivered as a pointer carrying `[mode: plan]`). Setup now uses a multi-mode vocation; the existing over-cap assertion follows the new pointer wording; the full-inbox fixture uses the new entry shape. |
| `test/nest/agents/agent/turn/executor_test.exs` | `restore_inbox` fixture uses the new entry shape; new test that `drain_inbox` applies the batch's human mode, labels both kinds in the combined text, and leaves the mode alone for an agent-only batch. |
| `test/nest/agents/agent/turn_acceptance_test.exs` | New test 1.1.10: a human message (`Agent.chat(pid, "human note", "plan", "alice")`) sent while the agent is genuinely `:executing_tools` (the tool batch is parked in a stubbed `Agents.send_message/4`) is queued with `kind: :user`, `mode: "plan"`, `from: "alice"`; `state.live.mode` is still `"chat"` at enqueue; after release the boundary drain delivers it (with the batch's `agents-send` entry) as one user message before the next request, with `[mode: plan]` and both labels in queue order, the status sequence never going `idle`, exactly two requests, the bridge ack before the delivered message, and `state.live.mode == "plan"` afterwards. |
| `test/nest_web/channels/agent_channel_chat_test.exs` | The old "rejects chat:message when the agent is `:compacting`" test is rewritten in place to "queues chat:message when the agent is `:compacting`" (reply `{:ok, _}`, entry queued with `kind: :user`, status unchanged, then the fabricated status is reset for the teardown); the describe is renamed "handle_in(chat:message) status dispositions". |
| `test/nest_web/channels/agent_channel_queued_message_test.exs` (new) | `chat:message` while `:streaming`/`:executing_tools` replies `{:ok, _}` (not `agent_busy`) and queues an entry with the socket username + requested mode; the `chat:inbox` reply carries `count`/`kind`/`mode`/`from`/`content`/`timestamp` and the `chat:status` reply carries `pendingMessageCount`; a broken status (`:needs_repair`) still replies `agent_status_needs_repair` and queues nothing new. |
| `test/support/agent_test_helpers.ex` | New `multi_mode_vocation_id_for_test/0` (`chat` default + `plan` + `review`) so a test can request a mode the agent is not already in. |
| `test/support/agent_turn_test_helpers.ex` (new) | The turn-stream helpers (`statuses_until_idle/1`, `assert_request/0`, `user_texts/1`, `text_of/1`, `tool_texts/1`) extracted from `turn_acceptance_test.exs` to keep that file under the credo source-file cap; reuses `AgentTestAssertions.text_from_parts/1` instead of a local copy. |
| `test/nest/agents/agent/needs_repair_test.exs`, `test/nest/agents/agent_recovery_test.exs` | Comments naming `chat_or_drop/3` → `chat_or_queue/4`. |
| `test/nest/agents/agent_context_warning_test.exs` | Two comments claiming the busy guard "rejects" a user message now say the message is queued while busy. |

## (b) Commands and results (verbatim)

`mix format <all changed files>` — clean (no further diffs). `mix compile --force --warnings-as-errors`:

```
Compiling 185 files (.ex)
Generated nest app
```

Focused runs (logs `notes/test-runs/task-d1-*.log`):

```
$ mix test test/nest/agents/agent/inbox_test.exs
15 tests, 0 failures

$ mix test test/nest/agents/agent/turn/executor_test.exs
34 tests, 0 failures

$ mix test test/nest/agents/agent/turn_acceptance_test.exs
10 tests, 0 failures

$ mix test test/nest_web/channels/agent_channel_chat_test.exs
23 tests, 0 failures

$ mix test test/nest_web/channels/agent_channel_queued_message_test.exs
1 test, 0 failures
```

Full set of touched/related files (log `notes/test-runs/task-d1.log`):

```
$ mix test test/nest/agents/agent/inbox_test.exs test/nest/agents/agent/turn/executor_test.exs \
  test/nest/agents/agent/turn_acceptance_test.exs test/nest/agents/agent/machine_test.exs \
  test/nest/agents/agent/machine_boundary_delivery_test.exs test/nest/agents/agent/machine_structure_test.exs \
  test/nest/agents/agent/guard_test.exs test/nest/agents/agent/needs_repair_test.exs \
  test/nest/agents/agent_recovery_test.exs test/nest/agents/agent_context_warning_test.exs \
  test/nest/agents/agent_chat_test.exs test/nest/agents/agent_chat_mode_test.exs \
  test/nest/agents/agent_user_message_mode_prefix_test.exs test/nest/agents/agent_stream_error_test.exs \
  test/nest/agents/agent_stop_test.exs test/nest/agents/agent_observability_test.exs \
  test/nest/agents/agent_system_messages_test.exs test/nest/agents/agent_post_tool_call_content_test.exs \
  test/nest/agents/agent/max_tokens_continuation_test.exs test/nest/agents/agent/tool_loop_send_agent_test.exs \
  test/nest/agents/agent/sub_agent_tools_test.exs test/nest/agents/agent/sub_agent_test.exs \
  test/nest/agents/agent/agents_batch_test.exs test/nest/agents/agent/clone_agent_flow_test.exs \
  test/nest/agents/agent/clone_agent_chat_stop_test.exs test/nest/agents/agent/clone_agent_registration_test.exs \
  test/nest/agents/agent/empty_response_reprompt_test.exs test/nest/agents/agent_compaction_test.exs \
  test/nest/agents/agent_compaction_preflight_test.exs test/nest/agents/agent_tools_iterations_test.exs \
  test/nest/agents/agent_tools_test.exs test/nest/agents/chat_task_cleanup_test.exs \
  test/nest/agents/chat_task_crash_test.exs test/nest/agents_test.exs \
  test/nest_web/channels/agent_channel_test.exs test/nest_web/channels/agent_channel_chat_test.exs \
  test/nest_web/channels/agent_channel_queued_message_test.exs \
  test/nest_web/channels/agent_channel_messaging_test.exs test/nest_web/channels/agent_channel_advanced_test.exs \
  test/nest_web/channels/agent_channel_needs_repair_test.exs \
  test/nest_web/channels/agent_channel_compaction_test.exs \
  test/nest_web/channels/agent_channel_compaction_loop_test.exs \
  test/nest_web/channels/agent_channel_chat_stop_test.exs \
  test/nest_web/channels/agent_channel_workspace_test.exs

Running ExUnit with seed: 91903, max_cases: 24

.......................................................................................................................................................................................................................................................................................................
Finished in 1.8 seconds (1.8s async, 0.00s sync)
359 tests, 0 failures
```

`mix credo` (log `notes/test-runs/task-d1-credo.log`):

```
Checking 405 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s to load, 0.8s running 72 checks on 405 files)
4039 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

**No failures in the final runs.** Negative control (the busy branch temporarily
replaced by the old drop, file restored in the same step and verified identical, then
the whole set re-run green) — test 1.1.10 fails, so it really does pin the queueing:

```
  1) test human messages during a turn 1.1.10 a human message queued inside a tool batch lands
     before the next request in its mode (Nest.Agents.Agent.TurnAcceptanceTest)
     test/nest/agents/agent/turn_acceptance_test.exs:581
       pattern: {:chat_inbox, %{count: 1}}
       value:   {:chat_status, %{ status: "executing_tools", … }}
     stacktrace:
       test/nest/agents/agent/turn_acceptance_test.exs:581: (test)

Finished in 1.0 seconds (1.0s async, 0.00s sync)
10 tests, 1 failure, 9 excluded
```

## (c) Deviations from the spec / where the spec looks wrong

1. **Two cap-forced splits.** (i) `test/nest_web/channels/agent_channel_chat_test.exs` was
   already 692/700 total lines, so the new channel coverage went into a new file
   (`agent_channel_queued_message_test.exs`) and the rewritten `:compacting` test keeps the
   old file at 699/700 by compressing its assertions. (ii) Adding the integration test pushed
   `turn_acceptance_test.exs` to 728/700, so I extracted its turn-stream helpers into
   `test/support/agent_turn_test_helpers.ex` (file now 673/700). No test was moved or deleted
   by (ii); nothing was removed from any assertion.
2. **The channel's rejected-status list is derived from `Machine.blocked_phases()`** rather
   than hand-written. It is the same five statuses the spec lists, and it cannot drift from
   the machine's vocabulary.
3. **Behaviour change beyond the spec's letter (an improvement, pinned by a test):** the old
   `chat_or_drop/3` only dropped for `:streaming`/`:executing_tools`/`:model_missing`/`:needs_repair`
   and **ran the pipeline for `:compacting`, `:compaction_failed`, `:context_overflow`, and
   `:compaction_loop_detected`** (the channel's rejection was the only thing stopping those).
   Now `:compacting` queues and every blocked status drops, per the spec's disposition table.
   The inbox test loops over all five blocked statuses to pin it.
4. **The human path ignores `@max_inbox_size`.** The spec makes the cap a property of
   `handle_delivery/3` only; a human `chat:message` is a cast with no reply channel, so a
   silent drop at 100 queued entries would lose the message. `enqueue_user_message/4`
   therefore queues unconditionally and documents why. Flagged for your call.
5. **Pointer wording changed** (not requested, but the old text is now false): the over-cap
   pointer said "You have 1 queued message **from another agent**"; it is now "You have 1
   queued message." / "You have N queued messages." The existing offload test's assertion was
   updated; the `:agent` combine labels are unchanged.
6. **The drain sets `state.live.mode` to the raw requested mode** (the spec's literal wording:
   "sets `state.live.mode` from the entry"). `Turn.build_ctx/2` resolves it for the delivered
   turn exactly as an idle chat does, so the `[mode: …]` prefix and caps are the resolved
   mode. Consequence: if a requested mode is not (or no longer) in the vocation, the status
   payload's `currentMode` shows the raw string until the next chat, while the delivered turn
   uses the vocation default. Nothing crashes (`Vocations.get_caps/2` returns
   `{:error, :unknown_mode}` and `resolve_caps` falls back to the default profile). I did not
   resolve at drain time because that would duplicate `ChatPipeline`'s resolution in the
   executor; say the word if you prefer the resolved value.
7. **Doc fixes beyond the listed files:** `Init.NeedsRepair`'s moduledoc and three test
   comments naming `chat_or_drop/3`, plus the two `agent_context_warning_test.exs` comments
   that claimed the busy guard rejects a user message. `Repair`'s moduledoc needed **no**
   change — it says "a message queued while the turn ran is drained at the `:generating`
   boundary" and makes no channel claim, which is true for both kinds (verified by reading
   it, no edit).
8. **One `review-c` finding adopted** because it is in a hunk I was already rewriting:
   `ChatState.Live`'s `inbox` doc now attributes the drain to the turn executor instead of
   `Inbox` (F8). Everything else in `review-c` is untouched (task C's, your triage). Two of
   them are worth a decision now that D1 landed: **F2** (`:loop_ack` clears a held
   `pending_user_message` without delivering it) is reachable from a queued *human* message
   via `start_chat/3`'s `:needs_compaction` branch, and **F4** (the 2000 ms fences) moved
   verbatim into the new helper module.

## (d) Anything unverified

- Did not run `mix precommit` or the full suite (per instructions); did not run any JS
  command and did not touch `assets/**` (D2's half). The browser end-to-end path
  (channel → queue → drain → optimistic-bubble retraction) is unverified; my channel test
  pins the server contract it depends on (reply `{:ok, _}`, the five-key `chat:inbox`
  payload, `pendingMessageCount`) and the Elixir integration test pins the delivery.
- An invalid/unknown requested mode is not covered by a test (see deviation 6); the mode
  tests use `plan`/`review` on a test vocation that defines them.
- The human path through the *channel* while the agent is `:compacting` is covered by the
  fabricated-status channel test, and the real drain path by the executor/inbox tests; a
  single end-to-end test that goes channel → `:compacting` → drain is not written (the
  fabricated status is the established pattern in that file).
- `mix credo` is Elixir-only; the Elixir suite subset I ran is 359 tests, not the whole
  suite (the team lead runs that).

---

# review-c follow-ups

All eight items from the lead's follow-up list are done in the same working tree
(no commits, no branch switches, no stash). Reported here rather than in a
separate file so the D1 record stays in one place.

| # | item | what was done |
| --- | --- | --- |
| 1 | **F2 — behaviour** | `do_step(%{phase: :compaction_loop_detected}, :loop_ack)` now re-appends a parked message: `nil -> [{:drain_inbox}]`, held -> `[{:append, {:user, user}}, {:drain_inbox}]`. The append runs first, so a refused append halts the executor (`{:append_result, :invalid, _}`) before the drain and surfaces as a visible turn failure; `pending_user_message` is cleared either way by the `enter/1` update. New `held_user/1` accepts both shapes production parks — `{:user_message, {:user, user}}` (the drain path's `Dispatch.build_user_message/2` tuple) and `{:user_message, user}` (a chat request) — plus `{:user, user}`; any other value counts as "nothing held", so a declared event never raises. New machine test `compaction loop ack keeps a held message` in `machine_boundary_delivery_test.exs` covers both held shapes (appended, `pending_user_message == nil`, `loop_count == 0`, phase `:idle`, `{:drain_inbox}` still emitted) and the no-held case (bare `[{:drain_inbox}]`). Negative control: with the clause reverted to the bare drain the new test fails (`right: [{:drain_inbox}]`); tree restored and re-run green. |
| 2 | **F3** | The `:needs_compaction` test now asserts its own precondition: `assert Dispatch.preflight_decision(projected, limit) == :needs_compaction, "the fixture must force the :needs_compaction branch"`, and the comment says 8_191 is one token under `Reserve`'s floor. I kept the derivation rather than deriving from `Reserve.compaction_reserve/1`, which is a function of the *limit*, not of the size. |
| 3 | **F4** | Both fences lowered 2000 → 500 ms in `test/support/agent_turn_test_helpers.ex` (where the helpers live since D1), and the module doc now states the cap. Stability: `mix test test/nest/agents/agent/turn_acceptance_test.exs --repeat-until-failure 20` → **21 runs × 10 tests, 0 failures** (`notes/test-runs/task-d1-repeat20.log`; first run 1.2 s, repeats 0.2 s each). |
| 4 | **F5** | The status-sequence comment now reads "…-> streaming (back from the tool batch; the delivery itself changes no status) -> idle", so it no longer implies the delivery produces a status change. |
| 5 | **F8** | Done during D1: `ChatState.Live`'s `inbox` doc names the turn executor (`Turn.Executor`'s `:drain_inbox` action / `Turn.drain_inbox/1`), not `Inbox`. |
| 6 | **F10** | The `assistant_tail` helper comment now says the `{:assistant, _}` tail is defensive today (the review's enumeration of every `:iterate` site found no production path), and why it is still handled: without the drain, `dispatch_http/1` → `Preflight.validate_request/1` → `:no_trailing_assistant` → `fail_turn`. I did **not** touch the design note (another agent has it modified in the tree). |
| 7 | **F11** | `generating_state/0` now sets `worker_ref: nil, active_worker: nil` (with a comment: `Phase.enter/4` clears them on the transition into `:generating` and `:iterate` is only emitted after the following append), so the fixture's "nothing is in flight" precondition is real. |
| 8 | **de-dup** | Both `{:inbox_drain, …}` clauses delegate to one private `deliver_inbox/3` (build the user message in `m.work.ctx.mode`, hand it to `start_chat/3`), placed in the "chat start / preflight" section with a comment that both boundaries share it. |

Sizes after the follow-ups (credo caps 500 code / 700 total): `transitions.ex`
686 total / 460 code — F2 added ~25 lines and the de-dup gave back ~5, so F12's
headroom warning stands (14 total lines left); `machine_boundary_delivery_test.exs`
352/221; `test/support/agent_turn_test_helpers.ex` 66/53;
`turn_acceptance_test.exs` 674/439.

Verification after the follow-ups:

```
$ mix format <changed files>            # clean
$ mix compile --force --warnings-as-errors
Compiling 185 files (.ex)
Generated nest app

$ mix test <the 45 touched/related files>     # notes/test-runs/task-d1.log
Running ExUnit with seed: 52209, max_cases: 24

........................................................................................................................................................................................................................................................................................................................................................................
Finished in 1.8 seconds (1.8s async, 0.00s sync)
360 tests, 0 failures

$ mix credo                                   # notes/test-runs/task-d1-credo.log
Checking 405 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s to load, 0.8s running 72 checks on 405 files)
4045 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

Also verified while doing item 1 (reasoning, not a new test): the re-appended held
message leaves the tail on a wire-`user` message, and the drain that follows
appends the combined queued entries onto it through the live bridge
(`Repair`/`MessageAppender` insert the alternation ack), so the two consecutive
user messages stay wire-legal. That bridge shape is already pinned by
`append_pairing_bridge_test.exs`.

Not addressed here (left for your triage): F1, F6, F7, F12 are note/doc items, and
F9's two note lines are already marked "superseded by #15" in the tree by another
agent. The design note is being edited concurrently, so I left it untouched.

## Follow-ups round 2 (the lead's two decisions + the F4 amendment)

| # | item | what was done |
| --- | --- | --- |
| 9 | **Deviation 6 — resolve the mode at drain time** | `Turn.Executor`'s `applied_mode/2` now runs the winning raw mode through the existing resolver: `ChatPipeline.resolve_mode_and_caps(requested, state.vocation, state.workspace_path, state.tmp_path) \|> elem(0)` (no duplicated resolution), with `nil` still meaning "leave the current mode alone". `Inbox.drain_mode/1` stays the pure selector and its doc now says the executor resolves the winner, exactly as an idle chat turn resolves its request — so `state.live.mode` (and the status payload's `currentMode`, which the UI's mode selector renders) can never hold a mode the vocation does not define. Tests: a new case in `inbox_test.exs`'s drain-mode table queues `mode: "bogus"` and asserts the drained `state.live.mode` and the delivered `[mode: chat]` prefix are the vocation default; `turn/executor_test.exs` gained a vocation fixture (`chat`/`plan`/`review`) plus a third case asserting the same fallback at the unit level. |
| 10 | **F4 — fences (amendment)** | The one fence I introduced over the cap is now 500 ms: `assert_receive {:tool_batch_blocked, worker}, 500` in test 1.1.10. Every other fence in my tests is ≤500 ms (`chat_inbox` 500, `refute_receive …, 50`); the pre-existing `, 2000`/`, 750` fences in tests 1.1.1–1.1.8 are not mine and were left alone. The stub's internal `after 5_000 -> :ok` safety valve stays, as agreed. |

Verification after round 2:

```
$ mix format <changed files>            # clean
$ mix compile --force --warnings-as-errors
Compiling 185 files (.ex)
Generated nest app

$ mix test test/nest/agents/agent/turn_acceptance_test.exs --repeat-until-failure 20
   # notes/test-runs/task-d1-repeat20.log
   21 suite runs x 10 tests, 0 failures (first run 1.2 s, repeats 0.2 s each)

$ mix test <the 45 touched/related files>     # notes/test-runs/task-d1.log
Running ExUnit with seed: 517305, max_cases: 24

........................................................................................................................................................................................................................................................................................................................................................................
Finished in 1.8 seconds (1.8s async, 0.00s sync)
360 tests, 0 failures

$ mix credo                                   # notes/test-runs/task-d1-credo.log
Checking 405 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s to load, 0.8s running 72 checks on 405 files)
4046 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

Note on `--repeat`: this Elixir (1.18) exposes `--repeat-until-failure N`, not
`--repeat N` (`mix help test`), so the equivalent was used: the file ran 21 times
(the initial run plus 20 repeats) with zero failures.

## Boundary extraction (review-c F12 / the file cap)

The turn-boundary decision moved out of `Transitions` into a new sibling
module, `Nest.Agents.Agent.Machine.Boundary` (alongside `Machine.Compaction`
and `Machine.Response`):

- **Moved:** `deliver_at_boundary?/1` (now the public `drain?/1`),
  `deliverable_tail?/1` and `inbox_count/1`, with all of their explanatory
  comments. The moduledoc carries the full rationale (the three conditions, the
  `force_finalize` guard, the tag-vs-`last_wire_role/1` reasoning, why the
  position inside the `[]` branch of `unpaired_tail_tool_uses/1` is load-bearing,
  the assistant-tail-is-defensive-today note, and the `inbox_count` 0 default
  for hand-built ctx fixtures), so nothing was lost at the call site.
- **Stayed in `Transitions`:** `iterate/1` (its `unpaired_tail_tool_uses/1` case
  is unchanged apart from the decision call), `dispatch_http/1`, every other
  transition, and all phase/kind writes (`Phase.enter/4`). `iterate/1`'s `[]`
  branch now reads:
  `if Boundary.drain?(m), do: {:ok, [{:drain_inbox}], m}, else: dispatch_http(m)`,
  with a comment pointing at the new module. The small
  `deliver_at_boundary_or_dispatch/1` wrapper was dropped rather than kept as a
  one-line delegation.
- **Tests:** unchanged; all 360 pass. The `machine_structure_test.exs` scans
  (`lib/nest/agents/agent/machine/*.ex` doc-block wording, "no side-door
  transition", "Turn is the only `Machine.step/2` caller") cover the new file
  and pass.

Sizes (credo caps 500 code / 700 total): `transitions.ex` **662 total / 452
code** (was 686/460 — 38 lines of headroom, up from 14);
`machine/boundary.ex` **75 total / 57 code**.

Verification:

```
$ mix format lib/nest/agents/agent/machine/boundary.ex \
             lib/nest/agents/agent/machine/transitions.ex   # clean
$ mix compile --force --warnings-as-errors
Compiling 185 files (.ex)
Generated nest app

$ mix test <the 45 touched/related files>     # notes/test-runs/task-d1.log
Running ExUnit with seed: 750927, max_cases: 24

........................................................................................................................................................................................................................................................................................................................................................................
Finished in 1.6 seconds (1.6s async, 0.00s sync)
360 tests, 0 failures

$ mix credo                                   # notes/test-runs/task-d1-credo.log
Checking 406 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s to load, 0.8s running 72 checks on 406 files)
4046 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

---

# review-d1 follow-ups

The lead's triage of `notes/review-d1.md`: items 1–8 accepted and implemented below;
D1-2/D1-4/D1-10 left as directed (behaviour unchanged, moduledoc/comment honesty
added where asked).

| # | item | what was done |
| --- | --- | --- |
| 1 | **D1-1 — non-string `content`** | `handle_in("chat:message", %{"content" => content} = payload, socket) when is_binary(content)` plus a fallback clause `handle_in("chat:message", _payload, socket)` replying `{:error, %{"reason" => "invalid_content"}}` (covers a missing key, which previously matched no clause and raised inside the channel server). A non-binary `mode` is normalized to `nil` by a new `requested_mode/1`. The reply mapping moved into `reply_chat/3` because the extra branches pushed `handle_in/3` over credo's ABC cap (34 → under 30). Channel tests added for a map content, a payload with no content key, and a non-string mode. |
| 2 | **D1-3 — normalize the held message** | `held_user/1` no longer re-implements a subset of the shape table: it normalizes through `unwrap_user/1` (the `Phase` defdelegate) and, when that cannot produce a `%User{}`, logs `"[turn] unrecognized pending_user_message: …"` and treats it as nothing held. The `:loop_ack` test now loops over all three accepted shapes (`{:user_message, {:user, user}}`, `{:user_message, user}`, and the legacy `{"legacy held message", "chat"}` tuple) and adds a captured-log case for an unrecognized value. |
| 3 | **D1-7 — validate `mode`/`from`** | `Inbox.put_entry/5` stores `from`/`mode` only when they are binaries (else `nil`), so `serialize/1` cannot put a number/map on the wire; `Inbox.label/1` now treats `""` like a missing sender (new `quoted/1` helper), making the moduledoc's "never puts `nil`/`""` in the prompt" claim true. Tests: the combine table gained blank-sender entries, and a new `enqueue_user_message/4` test pins the `nil` normalization for a map sender + numeric mode. |
| 4 | **D1-8 — log the broken-status drop** | `chat_or_queue/4`'s `true ->` branch logs `"[agent:<name>] dropping a chat message while status=<status>"`. Captured-and-asserted in `needs_repair_test.exs` (the existing capture block) and in `inbox_test.exs`'s blocked-status loop (which now wraps the loop in `capture_log` and asserts the warning for two of the five statuses — inclusion only). |
| 5 | **D1-9 — delete dead code** | `ChatPipeline.pending_user_message_struct/1` removed (no callers in `lib/` or `test/`; it also missed the drain shape). |
| 6 | **D1-5 — fix the overstatement** | The `:loop_ack` comment now says the message "lands in the transcript and is answered by the next turn; no turn is dispatched here (dispatching would re-enter the compaction decision that just gave up)". |
| 7 | **D1-6 — publish the mode change** | The `:drain_inbox` action computes the resolved mode, and when it differs from `state.live.mode` calls `Broadcasts.status/1` (the only carrier of `currentMode`) so the UI's mode selector does not lag until the turn ends. The acceptance test's exact sequence is now `["streaming", "executing_tools", "streaming", "streaming", "idle"]` with a comment that the second `streaming` is the delivery publishing the new mode (not a status change) and that the exact list still pins "no `idle` before the end". |
| 8 | **D1-11 — the stub valve** | Lowered `5_000` → `1_000` with a comment saying it exists only so a failing test cannot leave the tool worker (and the teardown) parked for long. |
| — | **D1-2 (rejected, doc-only)** | `Inbox`'s moduledoc now states that the human queue is unbounded (self-limited by human typing, no rate limiting anywhere in the app) and that each enqueue rebroadcasts the whole serialized list. Behaviour unchanged. |
| — | **D1-4 (tracked, comment-only)** | No behaviour change. The `:needs_compaction` test comment now says the parked message is "on the machine only, not on the wire (the executor has already emptied and rebroadcast the inbox), until the compaction commits and `resume_with_pending/1` appends it". |

Verification (full output, logs under `notes/test-runs/`):

```
$ mix format <changed files>            # clean
$ mix compile --force --warnings-as-errors
Compiling 186 files (.ex)
Generated nest app

$ mix test <the 45 touched/related files>     # notes/test-runs/task-d1.log
Running ExUnit with seed: 510371, max_cases: 24

..........................................................................................................................................................................................................................................................................................................................................................................
Finished in 1.7 seconds (1.7s async, 0.00s sync)
362 tests, 0 failures

$ mix test test/nest/agents/agent/turn_acceptance_test.exs --repeat-until-failure 20
                                              # notes/test-runs/task-d1-repeat20.log
   21 suite runs x 10 tests, 0 failures (exit 0)

$ mix credo                                   # notes/test-runs/task-d1-credo.log
Checking 406 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s load, 0.8s running 72 checks on 406 files)
4049 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

Negative controls run this round (each reverted in place, the file verified
byte-identical afterwards, then the suite re-run green):

```
# (a) D1-1: drop the `when is_binary(content)` guard
$ mix test test/nest_web/channels/agent_channel_queued_message_test.exs
     Assertion failed, no matching message after 100ms
     code: assert_receive %Phoenix.Socket.Reply{ref: ^ref, status: :error,
             payload: %{"reason" => "invalid_content"}}
2 tests, 1 failure

# (b) D1-8: drop the broken-status Logger.warning
$ mix test test/nest/agents/agent/inbox_test.exs
     Assertion with =~ failed
     code:  assert log =~ "dropping a chat message while status=:needs_repair"
16 tests, 1 failure
```

D1-6's assertion was itself exercised in the failing direction while
implementing it: before the sequence was updated, the run reported
`left: ["streaming", "executing_tools", "streaming", "streaming", "idle"]` vs the
old 4-element expectation — i.e. the acceptance assertion is sensitive to exactly
the extra `Broadcasts.status/1` this item adds.

File caps after this round (credo caps 500 code / 700 total): `agent_channel.ex`
**694 total** (6 lines of headroom — the reviewer's warning about this file
stands), `inbox.ex` 261, `transitions.ex` 662, `machine/boundary.ex` 75,
`turn_acceptance_test.exs` 687, `machine_boundary_delivery_test.exs` 376.

---

# review-pr28 follow-ups

The lead's triage of `notes/review-pr28.md`: findings 1 and 2 plus nits 5 and 6 were
ours to fix; nits 3/4 (the design note), 7/8 (process/artefacts) and observations 9/10
were left to the lead. `assets/**` untouched — finding 1's fix is server-side.

| # | item | what was done |
| --- | --- | --- |
| 1 | **Finding 1 — `pendingMessageCount` never on the `chat:status` broadcast** | `Broadcasts.status_payload/1` now carries `pendingMessageCount: length(state.live.inbox)` beside `currentMode:` (with a comment: a client that missed a `chat:inbox` frame recovers the count from the next status), so the client's `statusExtras` branch, its test and the PR-body claim are real. The payload function's `state.live`/`state.llm_metrics` reads were hoisted into `live`/`metrics` locals because the extra field pushed the function over credo's ABC cap (33 → clean). Test: the existing `agent_channel_test.exs` "chat:status broadcast carries currentMode (sticky mode)" assertion pattern was extended to `%{status: "idle", currentMode: "chat", pendingMessageCount: 0}` (no new test/setup), and the new composed test below asserts a **non-zero** count on a broadcast (`%{status: "streaming", pendingMessageCount: 2}`). |
| 2 | **Finding 2 — no test covers the composed channel → queue → drain → append → broadcast path** | New test `"a message pushed while a tool batch runs is queued, drained and broadcast as the turn"` in `agent_channel_queued_message_test.exs`: a dedicated agent on a multi-mode vocation is joined through the real channel; a real tool batch is parked in a `Mimic.stub(Nest.Agents, :send_message, …)` release valve (the `turn_acceptance_test.exs` trick, 1 s valve); the socket pushes `chat:message` while the agent is genuinely `:executing_tools`; after release it asserts the queued entry (`kind`/`from`/`mode`/verbatim `content`), the delivered `chat:message` **payload** the client receives (`"mode" => "plan"` distinguishes it from the turn-opening message, `"index"` equals the transcript row's index, one text part with `[mode: plan]`, `[Message from the user "<username>"]\nhuman note` then `[Message from agent "<name>"]\npeer note` in queue order), the transcript `[:system, :user, :assistant, :tool, :assistant, :user, :assistant]` with the bridge ack before the delivered row, the emptied inbox and unique indices. Per the reviewer's caution the test asserts payloads/transcript only — never a status sequence (the helper double-subscribes). |
| 5 | **Nit 5 — no compat cast clause** | `Callbacks`'s chat-cast clause now carries a comment saying the 4-tuple arity is deliberate and that the old 2-/3-tuple shape fails loudly with a `FunctionClauseError` instead of being silently dropped. No dead compat clause added. |
| 6 | **Nit 6 — the escalation consequence** | `Inbox`'s "One mode per delivery" section gained one sentence: with two queued human messages that asked for different modes, the *older* one executes under the newer one's caps and the model sees a single `[mode: X]` prefix for the whole batch (only the inbox panel shows each entry's requested mode). |

Verification (full output, logs under `notes/test-runs/`):

```
$ mix format <changed files>            # clean
$ mix compile --force --warnings-as-errors
Compiling 186 files (.ex)
Generated nest app

$ mix test <the 46 touched/related files>     # notes/test-runs/task-d1.log
Running ExUnit with seed: 186329, max_cases: 24

...................................................................................................................................................................................................................................................................................................................................................................................
Finished in 1.9 seconds (1.9s async, 0.00s sync)
371 tests, 0 failures

$ mix credo                                   # notes/test-runs/task-d1-credo.log
Checking 406 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s load, 0.8s running 72 checks on 406 files)
4050 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

Negative controls (each reverted in place, the file verified byte-identical, then the
suite re-run green):

```
# (a) finding 1: drop the field from the broadcast payload
$ mix test test/nest_web/channels/agent_channel_test.exs \
           test/nest_web/channels/agent_channel_queued_message_test.exs
   pattern: %{status: "idle", currentMode: "chat", pendingMessageCount: 0}
   pattern: %{status: "streaming", pendingMessageCount: 2}
32 tests, 2 failures

# (b) finding 2: the queued entry loses its sender (Inbox.put_entry/5 from -> nil)
$ mix test test/nest_web/channels/agent_channel_queued_message_test.exs
     Assertion with == failed
     code:  assert from == user.username
3 tests, 2 failures
```

File caps after this round (credo caps 500 code / 700 total):
`test/nest_web/channels/agent_channel_test.exs` is now **699/700 total** (459 code) — the
one-line-comment extension of the existing pattern is what took it there, so the next
change to that file must split it; `agent_channel_queued_message_test.exs` 277/182;
`broadcasts.ex` 367/221; `callbacks.ex` 266/130; `inbox.ex` 265/208.
