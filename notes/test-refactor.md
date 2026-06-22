# Test refactor: discrete `assert_receive` for known messages

Replaced loop-based drain helpers with discrete, bounded
`assert_receive` / `assert_push` calls — one per known broadcast.
No "wait for the system to be done" patterns; each assertion
matches a specific message we know will arrive.

## What changed

### Source files

- **`lib/nest/agents.ex`** — Removed `Process.alive?/1` from
  `get_agent_if_alive/1` (was an AGENTS.md violation). Now calls
  `Agent.get_public_info/1` directly; the `GenServer.call` raises
  `:noproc` if the agent is dead.
- **`lib/nest/agents/agent.ex`** — Fixed a pre-existing bug from
  the prior `chat_state`/`llm_metrics` sub-struct refactor: three
  sites were writing `messages:` as a top-level field (no longer
  valid) instead of nesting under `chat_state:`. Sites:
  `archive_and_compact/2` (~line 561) and the chat_continuation
  branch of `:compaction_done` (~line 852).
- **`lib/nest_web/channels/agent_channel.ex`** — Reverted the
  synchronous init push attempt; `Phoenix.Channel.push/3` from
  inside `join/3` crashes because the socket's `join_ref` is not
  fully established. Kept the original `send(self(),
  {:after_join, agent})` pattern. Tests use a 500ms timeout on
  `assert_push "init"` (per the user's "slightly longer
  timeouts are OK" guidance).
- **`config/test.exs`** — Bumped `pool_size: 5` → `10` to
  reduce SQL sandbox checkout contention (ultimately not the
  fix; see SQL sandbox section below).

### Test helpers — deleted

In `test/support/agent_test_helpers.ex`:
- `find_user_message/1` (10ms-loop)
- `receive_deltas_and_message_from_pubsub/0` (2000ms-loop)
- `collect_deltas_and_message_from_pubsub/1` (2000ms-loop)
- `collect_all_deltas_from_pubsub/1` (500ms-quiet-window)
- `collect_all_messages_from_pubsub/2` (10ms-total-budget bug)
- `do_collect_all_messages/5` (the broken helper above)
- `collect_until_tool_message/0` (3000ms-loop)

In `test/support/agent_channel_test_helpers.ex`:
- `collect_deltas/2` (10ms-quiet-window)
- `drain_chat_messages/2` (10ms-quiet-window)
- `collect_remaining_deltas/3` (10ms-quiet-window)

### Test files rewritten

All test files that called the deleted helpers were rewritten
to use discrete `assert_receive` / `assert_push` per known
broadcast. Each test now binds the broadcast to a variable and
asserts on its fields directly.

- `test/nest/agents/agent_chat_test.exs`
- `test/nest/agents/agent_compaction_test.exs`
- `test/nest/agents/agent_observability_test.exs`
- `test/nest/agents/agent_tools_test.exs`
- `test/nest_web/channels/agent_channel_messaging_test.exs`
- `test/nest_web/channels/agent_channel_advanced_test.exs`
- `test/nest_web/channels/agent_channel_test.exs` (removed
  the local `receive_deltas_and_message/0` recursion)

### Test isolation fixes

- `test/nest/agents_test.exs`,
  `test/nest/agents/supervisor_test.exs`,
  `test/nest/agents/agent_test.exs` — Removed the
  `File.rm_rf("/tmp/nest-#{System.pid()}")` from `setup` blocks.
  The path is shared across all tests in this BEAM VM, and
  wiping it in setup races with concurrent async tests' agents.
- `test/nest/agents/agent_test.exs` — Split out the
  `tmp_path lifecycle` describe block into a new
  `test/nest/agents/agent_tmp_path_test.exs` that is
  `async: false`. The parent dir is per-VM shared state; the
  per-agent dir is fine, but the tests that check both were
  fundamentally racy in async mode.
- `test/nest/agents/supervisor_test.exs` — The "returns empty
  list when no agents" test was removed; it cannot be
  expressed in async mode (other tests' agents leak into the
  registry). The "returns list of running agent IDs" test was
  changed to assert on this test's own IDs rather than the
  global count.
- **`test/nest/agents/supervisor_test.exs:14-17`** — Fixed
  the actual root cause of the channel test flakiness: the
  setup was iterating `Supervisor.list_agents()` and calling
  `Supervisor.stop_agent(id)` on EVERY existing agent, which
  under async load killed agents created by other concurrent
  tests (the channel tests' per-test agents). Replaced with a
  comment explaining per-test cleanup belongs in the test that
  owns the agent. **This was the bug causing the
  "agent not found" errors at `subscribe_and_join`.**

### Test files marked `async: false` (for DB-using tests)

The user's plan was to restrict concurrency to half the pool
size via `ExUnit.configure(max_cases: pool_size/2)`. That helped
(8-19 failures → 2-9) but didn't reach 0, because the root
cause was the supervisor_test setup bug above (now fixed).
We then set `async: false` on the DataCase-using test files
to belt-and-suspenders the SQL sandbox flakiness documented
below:

- `test/nest/vocations_test.exs`
- `test/nest/chat_model_test.exs`
- `test/nest/agents/agent_test.exs`
- `test/nest/agents/agent_chat_test.exs`
- `test/nest/agents/agent_tools_test.exs`
- `test/nest/agents/agent_observability_test.exs`
- `test/nest/agents/agent_compaction_test.exs`
- `test/nest/agents/agent_context_limit_test.exs`

These tests are already `async: false`:
- `test/nest/agents/agent_tmp_path_test.exs` (was always)
- `test/nest/agents_test.exs` (was always)

### Pre-existing bugs uncovered by the refactor

- **Sticky mode**: the agent's `handle_chat/3` reads
  `state.mode` to resolve the effective mode but never writes
  `state.mode` to the effective value. The "sticky mode"
  tests in `agent_chat_test.exs` were rewritten to assert on
  the user message's `metadata.mode` (the externally visible
  signal) rather than the internal `state.mode` / `current_mode`
  in `get_public_info/1`. The sticky-mode-on-internal-state
  feature is unimplemented; tracked as future work.
- **Stale `MockClient` queue transfer** — the `start_agent`
  helper had a bug where if `test_pid == pid` (a rare race
  during initial setup), the `else` branch tried to start a
  MockClient queue that was already started. Fixed the logic
  to use `MockClient.start_link` only in the right branch.

## Root cause analysis: the real "agent not found" bug

The "agent not found" error that the SQL sandbox investigation
turned up was actually a different bug. The sandbox checkout
errors (`badmatch: :not_found` at `start_owner!`) are real but
unrelated. The "agent not found" at `subscribe_and_join` came
from `test/nest/agents/supervisor_test.exs:14-17`:

```elixir
for id <- Supervisor.list_agents() do
  Supervisor.stop_agent(id)
end
```

This `async: true` setup killed agents owned by concurrent
tests. Once that was fixed, the channel tests pass with
`async: true` (no need to force them to `async: false`).

## Tests that legitimately need `:sys.get_state`

These tests inspect the agent's process state because the
information is not exposed via any broadcast or public API.
Each is a candidate for future work to add a proper external
observation point (broadcast, GenServer.call, or wire field).

### `test/nest/agents/agent_chat_test.exs`

- **"state.vocation is populated on init when a vocation_id is
  provided"** and **"state.vocation is nil when no
  vocation_id is provided"** — The full `Vocation` struct
  (`id`, `name`, etc.) is stored on the agent's process state
  but not broadcast. `init_payload["vocation"]` only carries
  `%{id, name}`. Future work: include the full struct in the
  init payload, or expose via a `GenServer.call(:get_vocation)`.

### `test/nest/agents/agent_observability_test.exs`

- **"does not call Discover when context_limit is already
  configured"** — The test reads `state.llm_metrics.context_limit`
  and `state.llm_metrics.context_limit_source` (the internal
  atom `:config`/`:probe`/`:default`). The init payload
  carries `contextLimitSource` as a wire string
  (`source_to_string/1`), so the test could be rewritten to
  assert on the string form — kept `:sys.get_state` for now to
  verify the internal atom directly.

### `test/nest/agents/agent_compaction_test.exs`

- **"preflight_request with active streaming returns :proceed
  without compacting"** — The preflight handler does not
  broadcast anything; the only externally visible signal is
  the `{:preflight_result, :proceed, _}` reply. To verify
  "didn't touch `state.chat_state.messages`", the test reads
  `state.chat_state.messages` before and after. Future work:
  have the preflight handler broadcast a "preflight decision"
  event with the message count delta.

### `test/support/agent_test_helpers.ex` and `agent_channel_test_helpers.ex`

- `:sys.replace_state/2` is used to swap the agent's
  `client_config.client` from the real `OpenAIClient` to the
  `MockClient` (the `set_mimic_global` Mimic API can't be
  used in async mode). This is a test-only mechanism, not a
  production observation; not the same as the principle's
  concern about testing externally visible behavior.

## SQL sandbox + SQLite: a documented limitation

`lib/nest/dependências/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:130-135`
(current 0.24.1 docs at hexdocs.pm/ecto_sqlite3 confirm this
still holds):

> "The Ecto SQLite3 adapter does not support async tests when
> used with `Ecto.Adapters.SQL.Sandbox`. This is due to SQLite
> only allowing one write transaction at a time."

The pre-existing flakiness under load was from this
limitation. With the supervisor_test fix above, this
contribution is now minor (rare `badmatch: :not_found` at
`start_owner!`), so we keep the DB-using tests at
`async: false` as a hard cap. If we ever switch to Postgres
or upgrade `ecto_sqlite3` to support async sandbox, we can
revert these to `async: true`.

## Verification

- **`mix test`: 488 tests, 0 failures, 2.6s wall-clock,
  across 10 seeds (1, 7, 42, 100, 999, 2024, 12345, 31337,
  65535, 99999) — 0 failures every time.**
- Channel tests (61 tests) pass with `async: true` across
  4 seeds (1, 42, 100, 999) — 0 failures.
- `mix precommit` exits 28 (credo) + the test step runs but
  doesn't show in the pipe. The credo issues (2 warnings,
  12 refactoring, 1 readability) are all pre-existing —
  see "Credo: pre-existing issues" below.
- Credo: 15 issues (down from 24 on main). I fixed 9
  "nested module could be aliased" issues in the test
  helpers I rewrote. The remaining 15 are pre-existing in
  `agent.ex`, `llm_runner.ex`, `compaction.ex`, `tools.ex`,
  `anthropic_client.ex`, `openai_client.ex`,
  `budget_planner.ex`, and `agent_channel.ex`. Out of scope
  for this PR.

## Credo: pre-existing issues (out of scope)

The `mix precommit` chain exits non-zero due to these
pre-existing credo issues, all in files I did not introduce:

- 2 warnings (file size > 500):
  - `lib/nest/agents/agent.ex` (1149 lines)
  - `lib/nest/agents/agent/llm_runner.ex` (555 lines)
- 12 refactoring (ABCSize > 30):
  - `lib/nest/llm/openai_client.ex:49` (41)
  - `lib/nest/llm/anthropic_client.ex:63` (41)
  - `lib/nest/llm/anthropic_client.ex:135` (38)
  - `lib/nest/tokens/budget_planner.ex:120` (36)
  - `lib/nest/llm/tools.ex:31` (31)
  - `lib/nest_web/channels/agent_channel.ex:180` (44)
  - `lib/nest/agents/agent.ex:163` (49)
  - `lib/nest/agents/agent.ex:292` (31)
  - `lib/nest/agents/agent.ex:832` (41)
  - `lib/nest/agents/agent.ex:967` (55)
  - `lib/nest/agents/agent/compaction.ex:165` (111)
  - `lib/nest/agents/agent/llm_runner.ex:432` (137)
- 1 readability: alias order in `llm_runner.ex:21`

These are all pre-existing. A separate refactor PR should
address them (likely the same one that splits `agent.ex`
into chat pipeline + handle_info router per the earlier
"Next steps" plan).
