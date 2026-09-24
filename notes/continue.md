# Continue: agent idle-before-teardown invariant

## Status: DONE (precommit green)

`mix precommit` passes cleanly: credo 0 issues, 1459 Elixir tests 0
failures (run twice), format clean, line caps OK, JS suite green.
Latest logs: `notes/test-runs/precommit-3.log`,
`notes/test-runs/teardown-full-4.log`.

## What the invariant is

No test may spawn an agent and finish while that agent still has a
chat turn in flight. The test process is the SQL-sandbox connection
owner; a turn that writes after the test exits fails with a Postgrex
"owner exited" error (and surfaces as an unrelated/flaky failure
elsewhere).

## Enforcement (structural, no per-test registration)

- `test/support/agent_test_lifecycle.ex`
  - `stop_test_agents/0` — discovers every agent owned by the test via
    `Nest.Agents.Registry.list_all/0`, filtered to spaces visible in
    the test's sandbox transaction (concurrent async tests' spaces are
    uncommitted and invisible). Stops each with a single `:DOWN` wait
    (no loops), and returns `%{owned, in_flight, still_alive}`.
  - `assert_zero_remaining!/1` — raises the explicit "expected zero
    remaining agents for this test" failure when an owned agent is
    still alive after teardown or was still in flight at body end.
  - In-flight statuses: `[:streaming, :executing_tools, :compacting]`.
    Other statuses (`:idle`, `:model_missing`, `:context_overflow`,
    `:compaction_failed`, `:compaction_loop_detected`) are frozen/
    terminal and cannot write to the DB.
  - `wait_for_pid_down/3` unchanged.
- `test/support/agent_test_macro.ex` — the `test/1,2,3` wrapper. It
  captures the body outcome (try/rescue/catch), always runs
  `stop_test_agents/0`, then re-raises the body exception if there was
  one; only a successful body is subject to
  `assert_zero_remaining!/1`. This guarantees cleanup can never mask a
  real test failure (verified with throwaway tests).
- `test/support/data_case.ex` / `channel_case.ex` import the wrapper.
- Removed: `track_agent/2`, `stop_tracked_agents!/0`, the tracking
  calls in `AgentTestHelpers`, and the manual `track_agent` in
  `clone_agent_flow_test.exs`.

Why discovery works: every agent process registers itself in
`Nest.Agents.Registry` via `Agent.start_link/1`
(`lib/nest/agents/agent.ex:137`), including production-spawned
children (`agents-spawn`/clone) and `start_supervised!({Agent, ...})`.
The sandbox-visible-space filter scopes ownership without any
bookkeeping. ChatTurns/tool workers need no separate tracking: all DB
writes are agent-mediated (`MessageAppender` runs inside the Agent;
ChatTurns only `GenServer.call` the Agent).

## Tests fixed to end terminal

- Driven to idle (were terminated mid-turn):
  - `test/nest/agents/agent_compaction_system_repeat_test.exs` —
    `run_compaction/3` no longer calls `ClientAPI.terminate`; it waits
    for the resumed turn's idle. Index assertion scoped to the
    compaction-produced prefix.
  - `test/nest/agents/agent_compaction_test.exs` "compaction_done
    archives ..." and `agent_compaction_preflight_test.exs`
    "compaction_done broadcasts ..." — wait for the resumed turn's
    idle instead of `Agent.terminate`.
- Fenced to terminal:
  - `agent_chat_turn_iteration_test.exs` (2 tests) — set a MockClient
    response and wait for `idle` after `executing_tools`.
  - `agent_agents_md_test.exs` (compaction resume) — wait for idle.
  - `agents_test.exs` "sends message to agent" — wait for idle instead
    of `eventually(message_count == 3)`.
  - Fabricated-status refusal tests restore `:idle` after asserting:
    `agent_workspace_test.exs`, `agent_change_model_test.exs`,
    `agent_channel_chat_test.exs` (`:compacting` rejection).
  - `agent_channel_chat_test.exs` — added idle fences before
    `chat:sync`/`chat:status` pushes to remove latent races in
    "returns a nil partial ...", "returns status with messageCount
    ...", "returns streaming status ...", and the two sync edge cases.
    The `chat:retry-compaction` test captures the expected preflight
    `chat:error` (the fabricated `:compaction_failed` + pending-user
    state resumes `[system, summary_user, user]`, which the wire
    preflight rejects).

## Known residuals / follow-ups

- Suite runtime is ~8-9s, above AGENTS.md's 5s target. It was already
  ~8.2s before this work; the per-test discovery query added ~0.5s.
  If the 5s budget must be met, the discovery query should be skipped
  for tests that never created a space (needs a cheap ownership hint).
- The `chat:retry-compaction` test's preflight 400 may indicate a real
  production issue: retrying a post-turn compaction with a
  `pending_user_message` appends the pending user after the
  `summary_user`, producing two `:user` wire roles. Worth a separate
  investigation; not touched here.
- Unrelated pre-existing working-tree changes from earlier API-log work
  remain (do not attribute them to this task).

## Verification

- `mix precommit` EXIT=0 (`notes/test-runs/precommit-3.log`).
- Full suite: 1459 tests, 0 failures, no test log prints.
- Throwaway tests confirmed both the violation raise and the
  no-masking behavior.
