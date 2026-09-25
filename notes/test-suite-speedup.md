# Test Suite Speedup

## Context

The suite is flaky under the default parallel configuration
(`max_cases: min(schedulers_online() * 2, 24)` -> 24 on this 12-core host),
but stable when run serially. The failures are always the same shape:
`assert_receive {:chat_status, %{status: "idle"}}, 500` (or a sibling
fence) times out with the mailbox holding only the user `chat_message`
and a `streaming` status — i.e. the turn is mid-flight, nothing crashed.

This note records the diagnosis and recommended fixes. It supersedes the
earlier `tiktoken` investigation, whose fix has already landed.

## What was already fixed: `tiktoken` -> `tokenizers`

The original hard failures (5-second `ExUnit.TimeoutError`s blocked in
`:code_server.call/1`) and the pathological per-turn latency traced to
two causes:

1. **`tiktoken`'s BPE vocabulary was `thread_local!`** in the Rust NIF
   (`deps/tiktoken/native/tiktoken/src/lib.rs`). Every dirty CPU
   scheduler thread (12 on this box) paid a ~200ms vocabulary build on
   its first call. Measured: 64 concurrent one-token calls produced 12
   calls at 184-218ms and 52 at 1ms — exactly the 12 dirty CPU threads.
2. **Code-server contention**: lazy module loading (`Jason`/JSONB) under
   `interactive` code-loading mode serialized on the single global code
   server, producing the 5s stalls.

Both are fixed:
- Migrated to `{:tokenizers, "~> 0.5"}` with a vendored
  `priv/tokenizers/cl100k_base.json`, loaded once into
  `:persistent_term` (`Nest.Tokens.Tokenizer`). The tokenizer is a shared
  Rust resource, so the vocabulary is built once per process, not once
  per scheduler thread. Token counts are identical (`"Hello, world!" == 4`).
- Added a module warm-up in `test/test_helper.exs` for the hot
  lazily-loaded modules.

Result: **zero hard timeouts** across many runs, and `--slowest` shows the
previously 155-320ms tokenization unit tests now run in 0.00ms.

## Current state

The remaining failures are **pure assertion-fence misses**, no hard
timeouts. Concurrency is the trigger:

| Configuration | Result |
| --- | --- |
| The 5-6 failing tests run together | 0 failures (0.8s) |
| Full suite, `--max-cases 1` | 0 failures |
| Full suite, `--max-cases 24` | 5-6 failures |

All failing mailboxes show `user` + `streaming` and nothing further. The
turn is running; it simply has not reached `idle` within the fence.

Measured turn latency for a failing test (single chat turn, crash path):
- run in isolation: ~76ms from `Agent.chat` to `:idle`
- inside the full serial suite: ~700-1000ms

The `{:chat_status, "idle"}` broadcast is emitted **last** in the turn
(`Nest.Agents.Agent.Handlers.ChatTurnHandler.chat_idle/1`), strictly after
the full stream is consumed, usage is merged, and the assistant message is
persisted. Every source of upstream latency therefore stacks in front of
the fence.

## Why it fails (ranked, verified)

### 1. DB round-trips per message append — dominant

`Nest.Agents.Agent.MessageAppender.append_one/2` calls
`Nest.Agents.Agent.Persistence.append_message/4`, which calls
`Nest.Persistence.insert_message/3`. That function does
`fetch_agent(space_id, name)` — a **SELECT** — on *every* append, then
`Repo.insert`, then `update_next_message_index` (another UPDATE). That is
roughly three DB statements per appended message.

The failing tests run 2-4 LLM turns each (tool call + final response), each
appending user/assistant/tool messages, all serialized through the single
Agent process. Under 24 concurrent tests on a 40-connection sandbox pool,
each statement queues behind other tests' writes.

### 2. `:sys.get_state` per stream event

`Nest.Agents.Agent.ChatTurn.HTTPWorker.check_should_stop?/1` calls
`:sys.get_state(state.ctx.agent_pid)` and is invoked by
`StreamConsumer.reduce/2` **before every event** — including
`:finish_reason` and `:done`, not just text deltas.

`:sys.get_state` is a synchronous system message to the Agent. The Agent's
mailbox is the same queue handling `{:delta_received, ...}` casts and the
DB appends above. So the HTTP worker ping-pongs with the very mailbox it is
flooding. A plain `set_response` turn is 3 events -> 3 synchronous barriers;
tool turns and `set_stream_events` turns scale with event count (the code
comment itself cites "1000-event streams").

### 3. Per-test teardown full-table scan

`Nest.Agents.AgentTestLifecycle.visible_space_ids/1` runs
`Repo.all(from s in Space, select: s.id)` — an unscoped `spaces` scan — on
**every test's** teardown. Under concurrency these scans contend with other
tests' in-flight turns for pool connections.

### 4. Global serialization points (secondary)

- `Mimic.allow/3` is three synchronous calls to a single global
  `Mimic.Coordinator` per `start_agent/1`
  (`test/support/agent_test_helpers.ex`). `Mimic.Server.apply/3` also does
  a synchronous `GenServer.call` to the owner's shard on each mocked call.
- `Nest.PubSub` is a single, unpartitioned process broadcasting ~3 status +
  N delta + ~2 message events per turn.
- `start_agent/1` performs several DB writes (space, vocation upsert, agent
  insert, `load_vocation` read) per test.

## Mechanism

At one test at a time the turn fits in the fence (~250ms). At 24 tests the
combined DB pool pressure, synchronous Agent round-trips, and PubSub fan-out
push the same turn past 500ms, so the fence fires. The tests are correct;
the latency is real and concurrency-amplified.

## Recommendations

Do **not** raise the fences. `SMELLS.md` forbids it: "Any increase in a
timeout is a likely smell. We need to find and fix the bug." Treat the
500ms fences as a canary and reduce the actual latency instead.

### Phase 1 — eliminate redundant DB work (highest impact, low risk)

- Stop doing a `fetch_agent/2` SELECT on every `insert_message/3` and
  `update_next_message_index/4`. Either cache the resolved agent row id in
  the Agent's runtime state and pass it down, or resolve it once per append
  batch rather than per statement.
- Merge the insert and the `next_message_index` update where possible, or
  move the index bump out of the per-append hot path.
- Target: remove ~1 SELECT per appended message.

### Phase 2 — remove the per-event `:sys.get_state` poll (high impact)

Replace `check_should_stop?/1`'s synchronous `:sys.get_state` with a
lock-free cancellation signal the worker can read without messaging the
Agent:

- Preferred: an `:atomics` (or `:ets`) cancel flag owned by the ChatTurn,
  written by the Agent's `handle_call({:stop_chat, _})` path, and read
  directly by the HTTP worker. This removes O(events) synchronous
  round-trips and the worker/Agent mailbox ping-pong.
- Confirm this is acceptable against the OTP guidance in `SMELLS.md`
  (which prefers calls over casts and discourages raw messages); a shared
  atomics flag is not a raw message and does not block the Agent.

### Phase 3 — test-harness contention (medium impact)

- Scope `visible_space_ids/1` so it does not scan the whole `spaces` table
  every test (query only spaces visible in the test's sandbox transaction,
  or use the Registry's space ids).
- Consider batching/removing the three `Mimic.allow` calls per test.
- Consider a partitioned `PubSub` in the test environment.

### Phase 4 — verify

- Re-run the reproducing seed (`803278`) at `--max-cases 24` and expect 0.
- Run at least two other seeds at `--max-cases 12` and `24`.
- Run `mix precommit` and read the full output.

## Open questions

1. Scope: do all four phases, or Phase 1+2 first and re-measure?
2. Phase 2: is an `:atomics`-backed cancel flag acceptable, or keep a
   (non-blocking, safe-point) call?
3. Phase 1: is caching the agent DB id in Agent runtime state acceptable,
   or keep the SELECT and only merge the writes?
4. Confirm the 500ms fences stay as-is (latency is fixed, not the fences).
