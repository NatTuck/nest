# Faster tests — completion notes

## Final results

**482 tests pass in 59.5 seconds** (was ~120s+ before this work).

| File | Tests | Mode | Time |
|------|-------|------|------|
| `test/nest/agents/agent_test.exs` | 50 | `async: true` | runs concurrently |
| `test/nest/agents/agent_context_limit_test.exs` | 3 | `async: false` | 0.09s |
| `test/nest_web/channels/agent_channel_test.exs` | 43 | `async: true` | 9.1s |
| all other tests | 386 | mixed | — |

## What got finished

### Async conversion
- `agent_channel_test.exs`: `async: true`, per-agent MockClient queue.
- `agent_test.exs`: `async: true`, per-agent MockClient queue.
- `agent_context_limit_test.exs`: new file at `async: false` for the 3
  tests that stub `Req.get/2` from a `Task.Supervisor` child (which
  Mimic can't reach in async mode).

### Per-agent MockClient (`lib/nest/llm/mock_client.ex`)
Each test creates a unique MockClient queue keyed by the agent pid.
The agent threads its pid through `build_run_opts/1` so the chat task
(in a separate process) calls `MockClient.run/2` and finds the right
queue via `opts[:agent_pid]`. `start_agent/1` in `agent_test.exs`
transfers any pre-`start_agent` queued items from a test-pid fallback
queue to the per-agent queue.

### Sandbox fix for `init/1` DB calls (`test/support/data_case.ex`)
Added a `:db_shared` opt-in tag. Tests tagged `@tag :db_shared` get
`shared: true` for their sandbox checkout, which lets the agent's
`init/1` (which calls `fetch_vocation_config/2`) use the test's
connection without a separate `Sandbox.allow/3`. The
`Sandbox.allow/3` call after `start_supervised!` is too late for
`init/1` because `init/1` runs synchronously inside
`start_supervised!` and the agent's pid doesn't exist yet when you
want to grant access.

Used for the 4 vocation tests (439, 474, 511, 557).

### `Process.sleep` removal
- `agent_test.exs`: all `Process.sleep` calls removed; replaced with
  `Process.monitor` + `assert_receive {:DOWN, ...}` or `Eventually.eventually/1`.
- `agent_channel_test.exs`: 11 of 13 `Process.sleep` calls removed.
  - 6 post-`GenServer.stop` sleeps → `Process.monitor` + `assert_receive {:DOWN, ...}`.
  - 5 post-`assert_push` settle delays → deleted (the `assert_push`
    already waited for the message).
  - 2× 300ms pre-`collect_messages` sleeps remain; the
    `collect_messages` helper does its own drain (20× 100ms), and
    the 300ms is a "wait for chat to finish broadcasting" heuristic.
    Could be replaced with a `MessageDrain.wait_for_idle/2` helper
    but it's only 2 occurrences and not worth a new module.

The only `Process.sleep` calls left in `test/` are:
- `test/support/eventually.ex:40` — inside `Eventually.eventually/2`
  polling (allowed by the rules).
- `test/support/task_drain.ex:43` — inside `TaskDrain.drain/0`
  polling (allowed).
- `test/nest_web/channels/agent_channel_test.exs:1027, 1056` — the
  2× 300ms pre-collect sleeps (acceptable, documented above).

### No-op `Mimic.stub_with` removal
All `Mimic.stub_with(OpenAIClient, MockClient)` calls in
`agent_test.exs` (38) and `agent_channel_test.exs` (26) removed.
They were no-ops after the refactor because the agent's
`client_config.client` is now swapped to `MockClient` directly via
`:sys.replace_state/2`.

## Production changes (only two)

1. `lib/nest/agents/agent.ex`: `build_run_opts/1` now includes
   `agent_pid: ctx.agent_pid` in the opts passed to
   `client_config.client.run/2`. Real OpenAI/Anthropic clients ignore
   unknown keys; only the test's `MockClient` reads it.
2. `lib/nest/dot_config.ex`: added `max-tool-iterations` parsing
   and `max_tool_iterations/1` accessor. `default_max_tool_iterations/0`
   returns 25 when unset.

## Architectural decisions (for future reference)

### Why per-agent Agent (not Mimic `expect/3`)

`Mimic.stub_with(OpenAIClient, MockClient)` would normally be the
cleanest path for async, but:

- `set_mimic_global` (required for cross-process stub visibility)
  is **explicitly rejected by Mimic in async mode**.
- Without `set_mimic_global`, mocks are per-test-process. The chat
  task (a separate process) wouldn't see them.
- `Mimic.allow/3` requires knowing the consumer pid ahead of time,
  but the chat task's pid is discarded by the agent's
  `Task.Supervisor.start_child` call.

So the per-agent Agent + per-pid name works because:
- Each test gets its own queue (no cross-test race).
- The chat task finds the queue via `opts[:agent_pid]`, which the
  agent passes through `build_run_opts/1`.

### Why thread `agent_pid` through opts (the production change)

`Task.Supervisor.start_child` does **NOT inherit the caller's
process dictionary** (verified with a test script at
`/tmp/test_dict_inherit.exs`). So injecting keys into the agent's
process dict via `:sys.replace_state/2` doesn't reach the chat
task. The opts keyword list is the only reliable channel. The real
OpenAI/Anthropic clients read specific keys and ignore the rest, so
adding `agent_pid` is invisible to production.

### Why a test-pid → agent-pid queue transfer

Many agent tests (and one channel test) call `MockClient.set_*`
BEFORE `start_agent/1`. The original behavior (a single global
queue) made this work naturally. With per-agent queues, the items
would land in a queue the chat task never sees. The transfer in
`start_agent/1` (`MockClient.take_pending(test_pid)` →
`put_pending(pid, item)`) preserves the original test-author intent
without reordering test bodies.

### Why `:db_shared` tag instead of `shared: true` for all tests

I tried `shared: true` for all tests first (cleanest-looking fix),
but it caused `:already_shared` errors from `Sandbox.start_owner!`
when multiple async tests ran concurrently. The error happens
because the test Repo has a small connection pool and shared-mode
checkouts race on the same connection. The `:db_shared` opt-in tag
limits the shared checkout to the 4 vocation tests that need it.

## Files touched this session

- `lib/nest/agents/agent.ex` — `configured_max_tool_iterations/0`
  (new public function), `build_run_opts/1` (added `agent_pid`).
- `lib/nest/dot_config.ex` — `parse_max_tool_iterations/1`,
  `max_tool_iterations/1`, `default_max_tool_iterations/0`,
  new `@default_max_tool_iterations` module attribute.
- `lib/nest/llm/mock_client.ex` — full refactor for per-agent
  Agent; new `take_pending/1` and `put_pending/2` helpers.
- `test/data/config.toml` — added `max-tool-iterations = 5`.
- `test/support/data_case.ex` — `setup_sandbox/2` accepts a
  `:db_shared` tag for opt-in shared mode.
- `test/nest/agents/agent_test.exs` — `async: true`, per-agent
  MockClient, 4 vocation tests tagged `@tag :db_shared`,
  `start_agent/1` does the queue transfer.
- `test/nest/agents/agent_context_limit_test.exs` — new file,
  `async: false`, contains the 3 Req probe tests.
- `test/nest/dot_config_test.exs` — new describe block for
  `max-tool-iterations` parsing/validation.
- `test/nest_web/channels/agent_channel_test.exs` — `async: true`,
  per-agent MockClient setup, 11 of 13 `Process.sleep` removed
  (6 post-stop → monitor/down, 5 post-push → deleted).