# Task C report — deliver queued inbox messages at the turn boundary (issue #15)

Scope: **task C only** (the machine half). Task D (human messages / channel / JS)
is owned by another agent and is not implemented or touched here.

## (a) Files changed

### Production (`lib/`)

| file | change |
| --- | --- |
| `lib/nest/agents/agent/machine/transitions.ex` | In `iterate/1`, the existing `[] ->` branch of the `MessageList.unpaired_tail_tool_uses/1` case now calls a new `deliver_at_boundary_or_dispatch/1`: when `ctx.inbox_count` is a positive integer, `work.force_finalize` is false and the transcript tail tag is `{:tool, _}` or `{:assistant, _}`, it emits `[{:drain_inbox}]` and returns the machine unchanged (still `:generating`/`:chat`, never `:idle`); otherwise it dispatches as before. Added `do_step(%{phase: :generating, kind: :chat} = m, {:inbox_drain, entries, content})` with the same body as the `:idle` clause (`Dispatch.build_user_message(content, m.work.ctx.mode)` + `start_chat(m, {:user_message, user}, entries)`), placed with the other `:generating`/`:chat` clauses. Added `deliver_at_boundary?/1`, `deliverable_tail?/1` and the documented `inbox_count/1` accessor (defaults to 0, `is_integer/1`-guarded because `nil > 0` is true in Erlang term order). No vocabulary change (`:drain_inbox` / `:inbox_drain` were already declared). |
| `lib/nest/agents/agent/turn.ex` | `build_ctx/2` now sets `inbox_count: length(state.live.inbox)` (one commented line). The machine struct itself is untouched (it is at the credo field cap). |
| `lib/nest/agents/agent/repair.ex` | Moduledoc, `classify_live/2` doc and the inline bridge comment corrected: the live bridge (user message onto a wire-`user` tail) is a normal path produced by the `:generating` `:inbox_drain` boundary delivery (issue #15), not an unreachable last-resort guard. Also removed the now-unsafe claim that the channel / `Callbacks.chat_or_drop/3` reject a user message mid-turn (task D changes that). |
| `lib/nest/agents/agent/message_appender.ex` | Moduledoc and the `@live_phases` comment: the one shape permitted on the live path is the turn-opening append **or** the turn-boundary inbox delivery; "a user message is rejected mid-turn" deleted. |
| `lib/nest/messages/message_list.ex` | `pairing_bridge/2` doc: the `{:tool, _}` tail (wire-`user`) is the common case at the turn-boundary delivery; `idle_bridge_ack/1` doc: dropped "the live exception is unreachable in production" and noted that the `:live` wording is exactly what the delivery appends. |
| `lib/nest/agents/agent/inbox.ex` | Moduledoc: a busy target's queued entries are drained at the next turn boundary (`Transitions.iterate/1` emits `:drain_inbox` from `:generating`/`:chat` once the wire sequence is complete), with `:idle` as the fallback — not "only when the target next goes idle". |
| `lib/nest/agents/agent/chat_state.ex` | `inbox` field doc: entries are drained at the next turn boundary (issue #15) or at `:idle`. |
| `lib/nest/tools.ex` | `agents-send` comment and LLM-facing description: queued messages are delivered at the target's next turn boundary — before it starts its next request, or when it goes idle if the turn ends first. |

### Tests

| file | change |
| --- | --- |
| `test/nest/agents/agent/machine_boundary_delivery_test.exs` (new, 6 tests) | Machine-level contract: (1) the drain fires (`{:drain_inbox}`, still `:generating`/`:chat`, status `:streaming`) for both a `{:tool, _}` and an `{:assistant, _}` tail; (2) it does not fire with an absent `inbox_count` key, `0`, `nil`, or `force_finalize: true` (each case still dispatches); (3) it does not fire onto a `{:user, _}` tail, nor onto an `{:assistant, _}` tail that still carries unanswered `Part.ToolUse` (that preflights instead — the load-bearing position); (4) `{:inbox_drain, entries, content}` in `:generating`/`:chat` appends the user message, defers `:iterate`, emits no `{:finalize, _}`, stays `:generating`, and resets the turn budget; (5) a delivered message that `:needs_compaction` is held on `pending_user_message` and stages the compaction; (6) a delivered message that `:cannot_compact` emits `{:restore_inbox, entries}` and blocks on `:context_overflow`. |
| `test/nest/agents/agent/turn_acceptance_test.exs` | New test 1.1.9: the model's first tool batch contains two `agents-send` calls to *itself*, so both messages are queued while the agent is `:executing_tools` (deterministic, no timing dependence). Asserts the exact `chat:status` sequence `["streaming", "executing_tools", "streaming", "idle"]` (never idle in between), `chat:inbox` counts 1 → 2 → 0, that the **next HTTP request already carried** the drained message (Mimic spy on `MockClient.run/2` + `Mimic.call_original/3`), exactly two requests, the drained order preserved, the live bridge ack inserted between the tool result and the delivered message, the queueing tool-result text, and normal turn completion (idle, no active worker, empty inbox, unique indices). |

`test/nest/agents/agent/machine_test.exs` is **byte-identical to HEAD** — see deviation 1.

## (b) Test commands and results (verbatim)

`mix format <all changed files>` — clean (no further diffs).

`mix compile --force --warnings-as-errors`:

```
Compiling 185 files (.ex)
Generated nest app
```

Focused runs:

```
$ mix test test/nest/agents/agent/machine_boundary_delivery_test.exs
Running ExUnit with seed: 986038, max_cases: 24

......
Finished in 0.1 seconds (0.1s async, 0.00s sync)
6 tests, 0 failures
```

```
$ mix test test/nest/agents/agent/turn_acceptance_test.exs
Running ExUnit with seed: 18018, max_cases: 24

.........
Finished in 1.0 seconds (1.0s async, 0.00s sync)
9 tests, 0 failures
```

Full required set (log: `notes/test-runs/task-c.log`):

```
$ mix test \
  test/nest/agents/agent/machine_test.exs \
  test/nest/agents/agent/machine_boundary_delivery_test.exs \
  test/nest/agents/agent/machine_structure_test.exs \
  test/nest/agents/agent/turn_acceptance_test.exs \
  test/nest/agents/agent/inbox_test.exs \
  test/nest/agents/agent/wire_invariant_test.exs \
  test/nest/agents/agent/append_pairing_bridge_test.exs \
  test/nest/agents/agent/machine/turn_test.exs \
  test/nest/agents/agent/machine/children_test.exs \
  test/nest/agents/agent/turn/executor_test.exs \
  test/nest/agents/agent/turn/commit_test.exs \
  test/nest/agents/agent/turn/messages_test.exs \
  test/nest/agents/agent/compaction/overflow_test.exs \
  test/nest/agents/agent/tool_loop_send_agent_test.exs \
  test/nest/agents/agent/message_append_tags_test.exs \
  test/nest/agents/agent/turn_structure_test.exs \
  test/nest/agents/agent/chat_pipeline_preflight_test.exs \
  test/nest/agents/agent/load_bridge_test.exs \
  test/nest/agents/agent/empty_response_reprompt_test.exs \
  test/nest/agents/agent/guard_test.exs \
  test/nest/agents/agent/sub_agent_tools_test.exs \
  test/nest/agents/agent/compaction_streamed_text_test.exs \
  test/nest/agents/agent_compaction_test.exs \
  test/nest/agents/agent_compaction_preflight_test.exs \
  test/nest/agents/agent_oversized_system_test.exs \
  test/nest/tools_test.exs \
  test/nest/agents/agent_chat_test.exs \
  test/nest/agents/agent_tools_iterations_test.exs \
  test/nest/agents/agent_tools_second_chance_test.exs

Running ExUnit with seed: 616356, max_cases: 24

.....................................................................................................................................................................................................................................
Finished in 0.9 seconds (0.9s async, 0.00s sync)
293 tests, 0 failures
```

`mix credo` (log: `notes/test-runs/task-c-credo.log`):

```
Checking 403 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.9 seconds (0.1s to load, 0.8s running 72 checks on 403 files)
4023 mods/funs, found no issues.

Use `mix credo explain` to explain issues or `mix credo --help` for options.
```

**No failures in the final runs** — there is no failure output to quote for the delivered state.

Negative control (feature temporarily short-circuited to prove the new integration test
really tests the delivery; the file was restored in the same step and verified identical,
then the whole set was re-run green):

```
  1) test turn-boundary inbox delivery 1.1.9 a message queued during a tool batch lands
     before the next request, with no idle (Nest.Agents.Agent.TurnAcceptanceTest)
     test/nest/agents/agent/turn_acceptance_test.exs:398
     Expected truthy, got false
     code: assert Enum.any?(user_texts(second), &(&1 =~ "[Message from agent"))
     arguments:

         # 1
         ["[mode: chat]\nqueue some messages"]

         # 2
         #Function<27.87051657/1 in Nest.Agents.Agent.TurnAcceptanceTest."test turn-boundary
         inbox delivery 1.1.9 ..."/1>
     stacktrace:
       test/nest/agents/agent/turn_acceptance_test.exs:465: (test)

Finished in 0.4 seconds (0.4s async, 0.00s sync)
9 tests, 1 failure, 8 excluded
```

## (c) Deviations from the design note / where the note looks wrong

1. **The machine-level tests are in a new file, not `machine_test.exs`.** That file was
   already 466 of the 500 allowed code lines; my block pushed it to 596 code lines / 870
   total lines and credo's `Nest.Credo.Check.SourceFileMaxLines` (`max_lines: 500`,
   `max_total_lines: 700`) failed. Since the project rule is "fix the lints, never bypass
   them", the block lives in `test/nest/agents/agent/machine_boundary_delivery_test.exs`
   (same style, intent comment on every assertion, `@moduledoc false` note saying why it is
   beside `machine_test.exs`). `machine_test.exs` is untouched. Putting them inside it
   requires moving other content out first.
2. **`message_list.ex:192-201` in the note has no stale claim in this revision** (those
   lines are the `pairing_bridge/2` body). The false claims were in the doc just above it
   (the `{:tool, _}`-tail case) and in `idle_bridge_ack/1`'s doc at 309-350 ("the live
   exception is unreachable in production"); I fixed those. The note's other line ranges
   (`repair.ex:24-28,97-100,113-115`, `message_appender.ex:38-41`, `inbox.ex:12-15`,
   `chat_state.ex:133-137`, `tools.ex:437-449`) matched exactly.
3. **Two extra stale spots fixed** (same now-false claim, not in the note's list):
   `message_appender.ex`'s `@live_phases` comment ("which can only be the turn-opening
   append") and the `:live` bullet of `message_list.ex`'s `idle_bridge_ack/1` doc. Comments
   that are still correct were left alone.
4. **`Repair`'s moduledoc no longer asserts** that "the channel and
   `Callbacks.chat_or_drop/3` reject it mid-turn". That sentence becomes false when task D
   lands and is not mine to assert either way; the replacement describes the boundary
   delivery instead.
5. **Test style:** `statuses_until_idle/1` is an ordered collector (not a mailbox drain
   loop) that stops at the first `idle` and flunks with the observed sequence; its 2 s
   `after` fence follows this file's existing `assert_receive …, 2000` convention rather
   than SMELLS' 500 ms guidance, to avoid a load-flaky fence (documented in a comment,
   including the concrete timing intent: the turn is two mock HTTP calls plus one in-memory
   tool batch). `refute_receive {:llm_request, _}, 50` uses the 50 ms convention.

## (d) Anything I could not verify

- Did not run `mix precommit` or the full Elixir suite (per instructions); did not run any
  JS command (no JS changes by me).
- The `:needs_compaction` and `:cannot_compact` branches are only exercised at the pure
  machine level, with a `context_limit` computed from `ConversationSize.size/1` to force the
  branch (the fits window is a few tokens wide). There is no full-agent integration test of
  the delivery through a compaction.
- The integration test queues via `agents-send` to self (the machine/executor queue path),
  not via the channel, so task D's half — human-message queueing, the
  `[Message from the user "<id>"]` framing, and the per-entry mode applied at drain time —
  is unverified here.
- The note's `agents-query` / `agents-wait` starvation concern (a peer that keeps receiving
  messages keeps starting turns) is not tested; the test only pins that no idle status is
  broadcast across the delivery.
- Concurrent work: another agent is editing `assets/js/**` in this same tree (those files
  are modified but untouched by me); `notes/` and `notes/test-runs/` hold the design note
  and the run logs.
