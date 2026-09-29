# CONTINUE — lazy archive (branch `clone-history-cleanup`)

Handoff for the **nest** repo. The root `notes/continue.md` is the DeepSeek V4
handoff — leave it alone.

## State

Branch `clone-history-cleanup`, based on `origin/main` = `b5728b7`, **6 commits
ahead, unpushed**, tip `65517f1` (a merge; it only brought in the SSE
event-name-drop fix, 4 files, orthogonal).

**The lazy-archive work (steps 2b + 2c) and the `:persistence_enabled` flag
removal (step 3) are now complete in the working tree, uncommitted.** It
compiles and `mix precommit` runs fully green:

- `notes/test-runs/precommit-final.log` — credo no issues, format clean,
  **1649 Elixir tests / 0 failures**, **1063 JS tests / 0 failures**, Elixir
  coverage 82.8% / JS 96.39%, no file over the size cap.
- Baseline before this work: `notes/test-runs/precommit-tip-baseline.log`
  (1636 Elixir tests).

## What landed (server, step 2b)

| file | change |
|---|---|
| `lib/nest/persistence/messages.ex` | new `load_slice/3` paged shared-prefix walk; `load_full_messages/2` delegates with `cap: :all, limit: :all`; `resolve_full/2` deleted |
| `lib/nest/persistence/history.ex` | `load/2` = `load_slice/3` with `limit: :all` (boundary-bounded, for `get_api_logs`); new `load_slice/3` (paged, role-filterable, `before`-exclusive) |
| `lib/nest/persistence.ex` | `load_history_slice/3` delegate |
| `lib/nest/agents.ex` | `build_agent_data/1` no longer loads (or ships) `history` — the join path does **no** archive read |
| `lib/nest/agents/agent/broadcasts.ex` | `compaction/3` → `compaction/2`; `:chat_compaction` carries the marker only |
| `lib/nest/agents/agent/compaction/result_handler.ex` | `Broadcasts.compaction(state, marker)` — the last in-agent DB read is gone |
| `lib/nest/agents/persisted_message.ex` | `to_runtime/1` copies `compaction_count` so a lazily-fetched marker agrees with the live broadcast |
| `lib/nest_web/channels/agent_channel.ex` | `build_init_payload/1` ships no `"history"`; new `handle_in("chat:history", ...)` + `history_opts/1` parsers + `@history_default_limit 50` / `@history_max_limit 200` / `@history_roles` |

The archive is never read at join. `chat:history` (channel process, pure DB
read, same shape as `chat:api-logs`) is the only reader; `load/2` stays for
`get_api_logs/3` (click-driven audit, out of scope).

## What landed (JS, step 2c)

- `store/slices/agentCache.js`:
  - `setAgentConnected` reads `lastCompactionIndex` / `compactionCount`
    (`?? existing ?? -1/0`), and drops `history` / `historyPrompts` /
    `lastCompactionMarker` when `compactionCount` changes.
  - `setAgentCompaction(id, marker)` replaces `setAgentHistory`; clears the
    stale projections and filters `messages` to `index > marker.index`.
  - new `setAgentCompactionMarker`, `setAgentHistorySlice` (merge pages, dedupe
    by index, ascending), `setAgentHistoryPrompts`.
  - `resetAgentConversation` resets the new fields.
- `store/slices/agentCacheStreaming.js`: dropped the dead `history` merge from
  `syncAgentMessages`.
- `channels/agent.js`: `loadArchiveProjections/1` (marker `{role: "compaction",
  limit: 1}` + 20 `{role: "user"}` prompts) fires after connect/rejoin and after
  `chat:compaction`; new exported `requestHistory(agentId, opts)`; init handler
  and rejoin `chat:status` both trigger it; `chat:compaction` no longer reads
  `payload.history`.
- Components: `ChatMessages` sources the marker from `lastCompactionMarker` and
  gates the card on `lastCompactionIndex`; `CompactionMarker` no longer bails on
  an empty `history` and lazy-loads on first expand; `CollapsedHistory` shows an
  explicit "Loading archived messages…" placeholder and a "Load older" button
  when the oldest loaded row isn't index 0; `ChatPage` builds the recall list
  from `historyPrompts` and owns `loadHistoryPage` / `loadOlderHistory`.
- `utils/chatHistory.js`: now extracts prompt text via `messageText` (part of
  the fix below) instead of requiring a flat `content`.

**One fix beyond the note:** archived rows from `chat:history` are wire format
(`parts`, no flat `content`), but `buildChatHistory` filtered on
`typeof m.content === "string"`, so the archived recall prompts would have been
silently dropped. It now reads through `messageText` (prefers `parts`, falls
back to legacy `content`), with a test for wire-format archived rows.

## What landed (step 3 — the `:persistence_enabled` flag is gone)

The defensive `Application.get_env(:nest, :persistence, %{})[:enabled] != false`
gate is deleted everywhere persistence is now unconditional:

- `lib/nest/persistence/agent_attrs.ex` — the five gates gone; the
  `do_update` / `do_update_workspace` / `do_archive` indirection inlined.
- `lib/nest/agents/agent/persistence.ex` — gates gone (module shrunk to the
  two public wrappers).
- `lib/nest/agents/supervisor.ex` — `persistence_enabled?/0`,
  `do_fetch_or_start_with_persistence/2`, `do_fetch_or_start_no_persistence/2`,
  and `do_on_demand_load_with_persistence/2` deleted; the persisted path is the
  only path, and `persistence_list_names_for_space/1` uses an implicit `try`.
- `lib/nest/agents/agent.ex` — `init/1` always calls `do_init/1`;
  `{:stop, :non_persistence_not_implemented}` and `persistence_enabled?/0`
  deleted.
- `config/test.exs` — the `config :nest, persistence: [enabled: true]` line and
  its comment removed.
- stale test/doc comments updated (`agent_persistence_test.exs`,
  `persisted_message_test.exs`, `persistence_test.exs`,
  `persistence_agents_test.exs`, `persistence/compaction_marker_test.exs`,
  `supervisor_persistence_test.exs`).

Note the handoff's Step-3 scope list omitted `agent_attrs.ex`, which was also
gated.

## Remaining work

### E. Finish

- (done) `mix precommit`, read the whole log, saved to
  `notes/test-runs/precommit-final.log`.
- (done) Refreshed this note.
- (done) Max-iterations test cleanup (see below) —
  `notes/test-runs/precommit-flake-fix.log` is green in *both* runs
  (1654 tests / 0 failures, seeds 674267 and 98599).
- Push `clone-history-cleanup` and commit the work (lazy archive + step 3
  + the test cleanup).

## Max-iterations test cleanup (the flaky 1.1.4)

`chat_turn_test.exs:206` (1.1.4) fenced 750 ms on `chat_status: idle`
after six sequential LLM rounds; the failing run's mailbox dump showed it
still streaming round 5 (`index: 14`, `call_5`) when the fence expired.
It was also unable to observe its own subject (nothing looked at the
request's `tools`) and inherited its cap from `test/data/config.toml`.

Three tests were converted to the **resumed-turn seam** — the production
`{:compaction_done, summary, carried_entry}` message, already used by
`agent_chat_turn_iteration_test.exs` — which seeds a turn with an
explicit `iter`/`max`, so a turn can start *at* the cap. No timeout
changed, no `async: false`, no Mimic, no mock changes.

| test | was | now |
|---|---|---|
| `chat_turn_test.exs` 1.1.4 | 6 LLM rounds | 1 |
| `agent_tools_max_iterations_test.exs` | 6 | 1 |
| `agent_tools_second_chance_test.exs` | 7 | 2 |

- New `test/nest/agents/agent/chat_turn/iteration_test.exs` asserts
  `Iteration.tool_config_for_iteration/1` directly (now public): tools
  pass through below the cap, `{nil, :none}` past it. That is the only
  assertion that actually pins `tools: nil`.
- `agent_tools_second_chance_test.exs` **was not testing the second
  chance at all**: its 6th scripted response was a `{:tool, _}` entry,
  and `MockClient.take_head(queue, nil)` skips leading `{:tool, _}`
  entries on a `tools: nil` call, so the turn finalized on the obedient
  path and `handle_overflow_tool_calls` never ran. The overflow round is
  now scripted with `set_stream_events/1` (events are not skipped), and
  the test asserts the synthetic `"Maximum tool iterations reached"`
  tool results are present — `synthetic_error_tool_results/1` has exactly
  one caller, so that assertion proves the path ran.
- Coverage note: no test now drives a *user-initiated* chat all the way
  to the cap (the entry tag is the only difference; `agent_tools_iterations_test.exs`
  still covers user chats counting rounds and refuting the notification).


## Notes / hazards

- `mix precommit` output is ~155 KB, mostly vitest's per-test lines; read it in
  full (never head/tail/grep a test run).
- Known unrelated flake: `test/nest/agents/agent_tools_test.exs:86` (100 ms
  budget vs a ~60 ms bwrap spawn).
- Also outstanding from `TODO.md`, unrelated: browser lag at ~100k context
  (this change is the bulk of it), rejecting invalid summaries, nested bwrap in
  tests.
