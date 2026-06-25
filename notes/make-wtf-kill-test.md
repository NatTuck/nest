# Make WTF kill the offending test

## Goal

When `Nest.Test.ReqNullAdapter` raises `WTF YOU TRIED TO DO A REAL HTTP REQUEST`,
the test that triggered the call should be marked as **failed** by ExUnit (with
the test name in the failure report), not produce a stray error log in the
output while the test silently passes.

## Current state

- The test pid is **not** currently in the Agent. The test process has
  `:nest_test_agent_pid` (pointing to the agent pid) in its own process dict.
  The agent has no record of the test pid.
- The chat task is started by the agent with
  `ctx = %{agent_pid: agent_pid, ...}` (no `test_id`).
- The chat task's `init/1` sets `Process.put(:"$callers", [agent_pid])`
  (chat_turn.ex:117) — for Mimic auto-allow, not for test_id.
- The HTTP worker is `spawn_link`'d by `OpenAIClient.run/2` (parent = chat
  task). The worker's `$callers` is just `[chat_task_pid]`.
- The previous `$callers`-walking approach failed because
  `Task.Supervisor.start_child` only sets the immediate parent in `$callers`,
  not the full ancestor chain.
- The WTF fires in the HTTP worker process. The worker is `spawn_link`'d to
  the chat task, not the test process, so the test process is unaffected by
  the worker's crash. The WTF shows up as a stray error log; the test passes.

## Threading the test pid: Agent → ReqNullAdapter

1. **Test process** — `Process.put(:nest_test_id, self())` in setup (or via
   case template). 1 line.

2. **Agent `init/1`** — read `Process.get(:nest_test_id)` and store in
   `state.test_id`. Add
   `handle_call(:get_test_id, _, state), do: {:reply, state.test_id, state}`.
   ~5 lines in `lib/nest/agents/agent.ex`.

3. **Chat task** — in `chat_turn.ex`, fetch test_id once at init via
   `GenServer.call(ctx.agent_pid, :get_test_id)`, store in `State`, include
   in `build_run_opts/1` output. ~4 lines.

4. **Runner** — pass `opts[:test_id]` through to `client.run/2`. 1 line in
   `lib/nest/llm/runner.ex`.

5. **OpenAIClient** — `run/2` reads `opts[:test_id]`, passes to
   `http_worker/6`. `http_worker` does `Process.put(:nest_test_id, test_id)`
   before `Req.post`. 3 lines in `lib/nest/llm/openai_client.ex`.

6. **ReqNullAdapter** — read `Process.get(:nest_test_id)` in `self()` (the
   worker). When raising WTF:
   - include the test id in the error message
   - `Process.exit(test_pid, :wtf)` to kill the test process

   ~5 lines in `lib/nest/test/req_null_adapter.ex`.

**Total: ~17 lines across 5 files.** No test-side changes required.

## Data flow

```
test process                          (sets :nest_test_id in own dict)
    │
    │ Process.get(:nest_test_id) in init/1
    ▼
agent state.test_id                   (set in init/1)
    │
    │ GenServer.call(:get_test_id) in chat_turn init
    ▼
chat task state.test_id               (stored in ChatTurn.State)
    │
    │ included in build_run_opts/1
    ▼
runner opts[:test_id]                 (passed through)
    │
    │ opts[:test_id] in client.run/2
    ▼
HTTP worker process dict              (Process.put(:nest_test_id, ...))
    │
    │ Process.get(:nest_test_id) in self() of adapter
    ▼
ReqNullAdapter.run/1                  (annotates message, Process.exit)
```

## Why Process.exit works without trap_exit

The test process is not trapping exits by default. `Process.exit(test_pid, :wtf)`
sends an exit signal that the test process cannot ignore. It dies with reason
`:wtf`. ExUnit's test runner monitors the test process; when it sees the test
process die, it marks the test as failed with the exit reason in the failure
report. The test name appears in the failure output, so the developer can
immediately identify the offender.

The "may leave orphan processes" risk is minor: `start_supervised!` (used by
most tests) ensures its children are cleaned up when the test process dies,
because they're linked to the test process and the test process dying
propagates the exit signal. Tests that use the application supervisor's
agents (e.g. `test/nest/agents_test.exs`) don't have this linkage, but their
agents are cleaned up in the next test's `setup` block.

## MockClient path is unaffected

When the agent is swapped to `MockClient`, the chat task calls
`MockClient.run/2` instead of `OpenAIClient.run/2`. No HTTP worker is spawned,
so no WTF can fire. The kill path is only triggered by real HTTP attempts,
which is exactly what we want.

## Non-agent tests are unaffected

Tests that don't create an agent (e.g. `test/nest/llm/discover_test.exs`)
directly call `Req.get` and use `Mimic.expect(Req, :get, ...)`. The WTF
wouldn't fire for these (Mimic intercepts the call before ReqNullAdapter
sees it). The kill path only affects tests that accidentally make real HTTP
calls.

## Out of scope

The other 4 test files that use `start_supervised!({Agent, ...})` without
`swap_to_mock_client` (`agent_test.exs`, `agent_observability_test.exs`,
`agent_system_messages_test.exs`, `agent_context_limit_test.exs`,
`agent_tmp_path_test.exs`) don't trigger the WTF in the bisect. They don't
dispatch chats that need an LLM response. Leave them alone.

## Verification

1. `mix test` — full suite should pass with no `WTF` in output (the
   bisect-found offender was already fixed: `test/nest/agents_test.exs:107`).
2. Temporarily revert the fix in `agents_test.exs:107` and re-run `mix test`
   to confirm the offending test is now marked as **failed** (not just a
   stray error log).
3. `mix precommit` — must pass.

## Files to edit

- `lib/nest/agents/agent.ex` — add `test_id` to state, `handle_call(:get_test_id)`
- `lib/nest/agents/agent/chat_turn.ex` — fetch test_id from agent, include in opts
- `lib/nest/llm/runner.ex` — pass `opts[:test_id]` through
- `lib/nest/llm/openai_client.ex` — read `opts[:test_id]`, stash in worker
- `lib/nest/test/req_null_adapter.ex` — read `:nest_test_id`, annotate + kill
