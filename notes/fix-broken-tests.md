# Broken tests

40 distinct tests that intermittently fail under the Elixir test suite.
All are now marked `FIXME: HIGH PRIORITY FLAKY TEST` and made to always-fail
per AGENTS.md line 80-81 (a flaky test is worse than a test that always
fails). The suite is reliably red on every seed (40 failures out of 697
tests, observed across seeds 0-100).

This supersedes the baseline in `notes/flaky-tests.md`, which described
the pre-Postgres state (16-29 failures across 8 seeds). The shape of the
flakes is the same as before — the source-code root causes have not
changed.

## How to find a test in this list

The 40 marked tests are searchable in the source by:

    grep -rEn "FIXME: HIGH PRIORITY FLAKY TEST" test/

Each test has both `IO.puts("FIXME: HIGH PRIORITY FLAKY TEST: <name>")`
and `flunk("FIXME: HIGH PRIORITY FLAKY TEST")` near the top of its
body. The flunk always raises, so the test always fails (no more
intermittent behavior in CI).

## How to fix a test in this list

Per AGENTS.md line 86-90:

> NEVER EVER increase an existing timeout to try to get a test to pass
> unless you have a concrete reason to believe that there's some external
> reason why we expect things to take a specific amount of time. A test
> unexpectedly hitting a timeout, even occasionally, means the test is
> critically broken and needs to be fixed so it's not timing-dependent.

Do **not** bump timeouts. The proper fix is to make the assertion
state-dependent, not time-dependent. Per AGENTS.md the canonical
patterns are:

    # Pattern A: wait for the GenServer to terminate (when it should)
    ref = Process.monitor(agent_pid)
    _ = :sys.get_state(agent_pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, timeout

    # Pattern B: explicitly await a deterministic state transition
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{id}")
    :ok = Agent.chat(pid, msg)
    assert_receive {:chat_status, %{status: "idle"}}, timeout
    _ = :sys.get_state(agent_pid)

The two existing helpers `Phoenix.PubSub.subscribe` +
`assert_receive {:chat_status, %{status: "idle"}}` already give the
test a deterministic fence — the "idle" status is only broadcast once
the chat pipeline has finished emitting every other event. Most of
the streaming tests should be restructured to assert on that single
fence rather than checking each intermediate event with a 100ms
timeout.

## Categories and root causes

40 tests across 5 categories. Source-code locations of the race are
listed per category.

### Category 1 — Sandbox / `:db_shared` (17 tests)

The Ecto SQL Sandbox is repo-wide-shared when any test sets
`Sandbox.mode(Repo, {:shared, parent})`. Once shared, every other
`:db_shared` test serializes against it, and any non-shared test
that needs `Repo` must contend for the same lock. Under load the
contention produces `DBConnection.OwnershipError cannot find
ownership process for #PID<...>` and similar failures.

Source: `test/support/data_case.ex:62-66`
(`Sandbox.mode(Repo, {:shared, parent})`) and
`test/support/agent_test_helpers.ex:20-32`
(`start_agent/1` spawns the agent under `start_supervised!`).

Important nuance: `config/test.exs:25` sets
`persistence_enabled: false`. `lib/nest/agents/agent/persistence.ex`
makes `append_message/3` and `archive_and_compact/4` no-ops. So
**no `Repo.insert/update_all` ever runs inside the agent subprocess,
ChatTurn, HTTP worker, compactor task, or context-limit probe task**.
The `Repo` calls in tests all originate in the test process itself
(`Vocations.create_vocation/1`, `Init.load_vocation/1` called from
`agent_test_helpers.ex:56`).

Fix direction: remove the `@tag :db_shared` from the 13 agent-system
tests below. The vocation is already pre-fetched in the test process
by `Init.load_vocation/1` in the helper, so the agent subprocess
doesn't need shared sandbox access.

Affected tests:

- `test/nest/vocations_test.exs:22` — list_vocations/0 returns all vocations
- `test/nest/vocations_test.exs:29` — get_vocation!/1 returns the vocation with given id
- `test/nest/vocations_test.exs:39` — create_vocation/1 with valid data creates a vocation
- `test/nest/vocations_test.exs:66` — update_vocation/2 with valid data updates the vocation
- `test/nest/vocations_test.exs:90` — update_vocation/2 with invalid data returns error changeset
- `test/nest/vocations_test.exs:101` — delete_vocation/1 deletes the vocation
- `test/nest/vocations_test.exs:109` — change_vocation/1 returns a vocation changeset
- `test/nest/vocations_test.exs:118` — valid modes with caps pass validation
- `test/nest/vocations_test.exs:137` — nil modes pass validation (legacy vocations)
- `test/nest/vocations_test.exs:151` — empty modes pass validation
- `test/nest/agents/agent_agents_md_test.exs:44` — includes AGENTS.md content when file exists in workspace
- `test/nest/agents/agent_agents_md_test.exs:70` — omits AGENTS.md section when workspace has no such file
- `test/nest/agents/agent_agents_md_test.exs:99` — omits AGENTS.md section when workspace_path is nil
- `test/nest/agents/agent_system_prompt_composition_test.exs:32` — vocation system_prompt gets the mode catalog and a [Workspace] section
- `test/nest/agents/agent_system_prompt_composition_test.exs:79` — no workspace line when workspace_path is nil
- `test/nest/agents/agent_system_prompt_composition_test.exs:117` — configured context limit shows the confident value with its source
- `test/nest/agents/agent_system_prompt_composition_test.exs:158` — default context limit (no configured value) shows the default caveat

(The 10 `vocations_test.exs` tests also race on the same shared lock
when they run in the same async partition as a `:db_shared` test;
the fix is the same — they don't actually need shared mode either.)

### Category 2 — Streaming PubSub timing (12 tests)

Tests `Phoenix.PubSub.subscribe` then `Agent.chat/2` and chain
`assert_receive` calls with 100ms timeouts against
`:chat_message`, `:chat_delta`, `:chat_status`. The chat pipeline
emits these in order from the agent's GenServer handler at
`lib/nest/agents/agent/chat_pipeline.ex:59-70`. The broadcast order
is deterministic — the failure mode is that the BEAM scheduler
delays the agent's cast handler past 100ms under contention.

Source: `lib/nest/agents/agent/chat_pipeline.ex:59-70`
(`Broadcasts.message/2` → `Broadcasts.status/2` → `spawn_chat_turn/1`)
and `lib/nest/agents/agent/broadcasts.ex`
(the single source of all `Phoenix.PubSub.broadcast/3` calls).

The system-message broadcast always goes to a not-yet-subscribed
test process because `lib/nest/agents/agent/init.ex:116` broadcasts
during `init/1` *before* `start_supervised!` returns. This is by
design — `init.ex:105-112` documents it.

Fix direction: restructure each test to subscribe → `Agent.chat` →
single `assert_receive {:chat_status, %{status: "idle"}}, timeout`
fence. Then `_ = :sys.get_state(agent_pid)` and assert on the
final state. Drop every per-event 100ms `assert_receive`.

Affected tests:

- `test/nest/agents/agent_chat_test.exs:31` — broadcasts user message and LLM response via PubSub
- `test/nest/agents/agent_chat_test.exs:52` — broadcasts status changes via PubSub
- `test/nest/agents/agent_chat_test.exs:66` — handles LLM error gracefully
- `test/nest/agents/agent_chat_test.exs:90` — LLM error path returns a RunState
- `test/nest/agents/agent_chat_test.exs:113` — accumulates delta content from streaming LLM response
- `test/nest/agents/agent_chat_test.exs:142` — accumulates deltas with correct character counts
- `test/nest/agents/agent_chat_test.exs:207` — vocation with modes: requested mode is preserved when valid
- `test/nest/agents/agent_chat_test.exs:251` — vocation with modes: unknown mode falls back to the vocation's default
- `test/nest/agents/agent_chat_test.exs:296` — user messages carry the resolved mode in metadata
- `test/nest/agents/agent_chat_test.exs:345` — state.mode is updated to the resolved mode after a chat (sticky mode)
- `test/nest/agents/agent_chat_test.exs:392` — state.mode falls back to vocation default when the requested mode is unknown
- `test/nest/agents/agent_chat_test.exs:433` — user message metadata falls back to vocation's default mode
- `test/nest/agents/agent_chat_test.exs:478` — state.vocation is populated on init when a vocation_id is provided

### Category 3 — Tool budget loop order (6 tests)

These tests set up MockClient with multiple `tool_call_start` events
and assert on the resulting tool-message order. There is **no
`Task.async_stream` anywhere in the production code path** —
`lib/nest/tokens/budget_planner.ex:107-121` walks tool calls
sequentially and `lib/nest/agents/agent/chat_turn.ex:332-338` spawns
a single task that calls `ToolLoop.execute/3`. Tool-result order is
deterministic. The flakiness is from the same 100ms timeout issue
as Category 2 — the events stream to the test's mailbox out of
assertion order.

Source: `lib/nest/llm/mock_client.ex:234-249` (`tool_stream/1`),
`lib/nest/tokens/budget_planner.ex:107-121` (`do_execute/4`),
`lib/nest/agents/agent/chat_turn.ex:332-338`
(`Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn -> ...)`).

Subtle: `MockClient.tool_stream/1` emits `tool_call_start` events
without an `:index` field. `lib/nest/llm/client.ex:128-134` defaults
`idx = 0`, so the test's two-call case puts both calls at index 0.
This happens to work because the keys are string IDs and `Map.values/1`
preserves small-map insertion order, but the order is not load-bearing.

Fix direction: same as Category 2 — fence on `:chat_status` "idle",
then assert on the persisted `state.chat_state.messages` after
`:sys.get_state(agent_pid)`.

Affected tests:

- `test/nest/agents/agent_compaction_test.exs:62` — small tool results pass through unchanged
- `test/nest/agents/agent_compaction_test.exs:108` — order is preserved when multiple tool calls are returned
- `test/nest/agents/agent_compaction_test.exs:167` — compaction_done archives previous messages to history with a marker
- `test/nest/agents/agent_compaction_test.exs:220` — preflight_request with active streaming returns :proceed without compacting
- `test/nest/agents/agent_compaction_test.exs:253` — preflight_request with empty streaming_acc and fits returns :proceed
- `test/nest/agents/agent_compaction_test.exs:344` — compaction_done broadcasts chat:compaction with marker and history

### Category 4 — `chat_crashed` partial content (1 test)

The chat_turn_handler emits a partial assistant message
(`chat_turn_handler.ex:123-144`) before the `:chat_error` event. The
Mimic stub at `chat_task_crash_test.exs:200` sends `{:delta_received,
"Halfway through...", :text}` then raises. The send+raise order
should guarantee the partial lands in the agent's mailbox before the
crash handler runs. The 200ms `assert_receive` timeout is too tight
to see the partial message reliably.

Source: `lib/nest/agents/agent/handlers/chat_turn_handler.ex:123-144`
(the `chat_crashed/3` broadcast order) and
`lib/nest/agents/agent/chat_turn.ex:135-154`
(`{:worker_crashed, ex, stacktrace}` send path).

Affected tests:

- `test/nest/agents/chat_task_crash_test.exs:180` — partial streaming content is saved as a normal assistant message before the error is broadcast

Fix direction: fence on `:chat_status` "idle" (or `:chat_error`),
then assert on the persisted partial message in
`state.chat_state.messages`.

### Category 5 — Web channel tests (2 tests)

`Phoenix.ChannelTest` pushes the WS reply synchronously to the test
mailbox. The next `assert_push "chat:message", ...` waits for the
agent's PubSub broadcast to flow through the channel process's
`handle_info` and back to the test. That's a separate hop and 500ms
timeouts are too tight on busy CI.

Source: `lib/nest_web/channels/agent_channel.ex:142-153`
(`handle_in("chat:message", ...)`) and lines 69-73
(`handle_info({:chat_message, ...}, socket)`).

Subtle: Phoenix.ChannelTest's in-flight mailbox is FIFO. A push
that arrives before `assert_push` matches the FIRST `assert_push`
after it. This means tests that re-use a socket across multiple
`chat:message` pushes without draining can interleave replies from
prior turns with current-turn events. The 2000ms timeouts already
on `agent_channel_chat_test.exs:36-37, 48-49, 81, 162-163, 184,
215, 243-244, 370-372, 383-387` are fine; the 500ms ones are the
ones to widen — but per AGENTS.md the right fix is to wait on a
deterministic `:chat_status` "idle" push (or the equivalent
`channel_joined` / explicit-fence helper) instead of bumping the
timeout.

Affected tests:

- `test/nest_web/channels/agent_channel_chat_test.exs:203` — returns empty messages when lastIndex exceeds server's messageCount
- `test/nest_web/channels/agent_channel_messaging_test.exs:144` — status transitions idle -> streaming -> idle

## Files touched by the marking pass

- `test/nest/vocations_test.exs` — 10 tests
- `test/nest/agents/agent_chat_test.exs` — 13 tests
- `test/nest/agents/agent_compaction_test.exs` — 6 tests
- `test/nest/agents/agent_agents_md_test.exs` — 3 tests
- `test/nest/agents/agent_system_prompt_composition_test.exs` — 4 tests
- `test/nest/agents/agent_post_tool_call_content_test.exs` — 1 test
- `test/nest/agents/chat_task_crash_test.exs` — 1 test
- `test/nest_web/channels/agent_channel_chat_test.exs` — 1 test
- `test/nest_web/channels/agent_channel_messaging_test.exs` — 1 test

Total: 40 marked tests across 9 files.

## Suggested order to fix

1. **Category 1** (17 tests) — lowest risk, no test rewrite, just
   remove `@tag :db_shared` where the helper pre-fetches the
   vocation. Confirm each test still passes alone first.
2. **Category 2** (13 tests) — pick one test as the template
   (e.g. `agent_chat_test.exs:142` — accumulates deltas with
   correct character counts), write the fence-on-idle pattern,
   then apply it to the other 12.
3. **Category 3** (6 tests) — same fence-on-idle pattern.
4. **Category 4** (1 test) — apply the same pattern.
5. **Category 5** (2 tests) — same pattern adapted to
   `assert_push` on `:chat_status` "idle" instead of
   `assert_receive`.

After each batch, run `mix test --seed <N>` for 50 distinct seeds
to verify the test never flakes, then move to the next batch.