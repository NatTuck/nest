# PR #19 review findings

Scope: `git diff main...HEAD` (75 files), weighted toward `7270534`, `a3901ae` and `696d642`.
Every claim below was checked by reading the code; line numbers are at HEAD (`696d642`).
Targeted verification run (full output read, not piped):

- `mix test` on `load_bridge_test`, `needs_repair_test`, `tool_loop_query_error_test`,
  `batch_sizer_overflow_test`, `batch_sizer_test`, `machine_test`, `visibility_test`,
  `agents_batch_test`, `sub_agent_tools_test` → 111 tests, 0 failures
  (`notes/test-runs/pr19-review-elixir-1.log`).
- `mix test` on `agent_channel_chat_test`, `agent_chat_test`, `append_pairing_bridge_test`,
  `message_append_tags_test`, `agents_test`, `tool_loop_clone_agent_test` → 72 tests, 0 failures
  (`notes/test-runs/pr19-review-elixir-2.log`).
- `cd assets && pnpm vitest run` on `useScrollToBottom`, `slashCommands`, `ChatInput` → 93 passed;
  and on `ChatPage`, `channels`, `store/index`, `App`, `NewSpacePage` → 466 passed
  (`notes/test-runs/pr19-review-js-1.log`, `-2.log`).

## BLOCKER

NO BLOCKERS

## SHOULD-FIX

- `test/nest/agents/agent/load_bridge_test.exs:83-109` — `"folds the healed bridge into attrs in the
  caller's DB context"` is fully subsumed by `"a second heal of the same tail appends nothing"`
  (`:126-169`): same setup (`insert_agent` + `[system(0), user(1, "hi")]` + `build_attrs_for_start`),
  and every assertion of the first test is repeated verbatim in the second, which additionally pins
  the `chat:message` broadcast, the idempotent re-check and the indexed persisted sequence. Per
  AGENTS.md ("Merge tests with same setup and non-conflicting assertions"), delete the `:83` test and
  keep its `Persistence.load_messages/2` role assertion inside the `:126` test if it is still wanted
  (the `:126` test already asserts `persisted_sequence/2` with indices, a superset).
- `assets/js/store/slices/agentCache.js:109-111` — the comment ("`chat:status` (the rejoin path)
  carries neither field, so the `?? existing` fallback is what preserves them across a plain
  reconnect") is false, and this PR's own rewrite says the opposite at `assets/js/channels/agent.js:271-276`.
  The `chat:status` *reply* does send both fields (`lib/nest_web/channels/agent_channel.ex:473-474`,
  and `:266-267` for `init`), and those are the only two payloads `setAgentConnected/2` ever receives
  (`assets/js/channels/agent.js:269`, `:294`), so the fallback is unreachable in production — it is
  only exercised by test fixtures that omit the keys (e.g. `assets/js/channels.test.js`'s
  `setAgentConnected("agent-1", {model, messageCount, messages})`). Minimal fix: say the fallback is
  for payloads/fixtures that omit the fields, and drop the "carries neither field" claim.

## NIT

- `test/nest/agents/agent/load_bridge_test.exs:284` — `assert in_memory_sequence(healed_a) == persisted`
  is near-tautological: `healed_a` is built from the same `initial` list and the same `ack` as
  `state_a`, so its in-memory sequence is `[{0,:system},{1,:user},{2,:assistant}]` by construction
  (it only fails if the append itself failed). Only the `:285` assertion on `healed_b` — the caller
  whose row the unique index drops — carries information; the comment above them ("Both in-memory
  sequences match the persisted one") would read more honestly if it said that.
- `notes/issue-08-user-after-user-bridge.md:69` — the citation this PR edited to fix a stale reference
  is wrong in a new way: `init/load_heal.ex:36-57` is `refresh/1`'s `@doc` block; `heal/2` is at
  `lib/nest/agents/agent/init/load_heal.ex:78-96`. The same row's behavior column is also stale after
  this PR: a valid slice ending on a user role no longer falls through to `:needs_repair`, it gets
  `{:bridge, _}` (`lib/nest/agents/agent/repair.ex:150-154` → `lib/nest/persistence.ex:457`).
- `test/nest/agents/agent/agents_batch_test.exs:147` — the new test's `assert_receive {:chat_status,
  %{status: "idle"}}, 2_000` is over SMELLS' 500ms ceiling with no comment giving measured timings. It
  matches the file's existing convention (5 pre-existing `2_000` fences) and costs nothing on success,
  so this is a file-wide smell rather than a new one, but the new line does add to it.

## Checked and clean

- `init/1` is DB-free: `do_init/1` → `build_active_state/2` → `Init.build_state/2` (`Nest.Models.context_limit/2`
  is an in-memory GenServer, `TmpSpace.create/1` is filesystem) and `Init.seed_from_db/4`; the
  `:model_missing` path (`Init.Recovery.build/3`) and the violations path (`Init.NeedsRepair.block/3`)
  are pure too. All heal writes go through the caller's pid (`Agent.pre_load_heal/1` from
  `Supervisor.fetch_or_start_agent/2` and `start_under_test/1`), never the supervisor-spawned child.
- Claim "two concurrent joins cannot double-heal": the re-check (`Init.LoadHeal.refresh/1`) closes the
  ordinary race, and the residual same-instant interleaving is genuinely collision-safe —
  `insert_message/3` uses `on_conflict: :nothing` on the unique `(agent_id, message_index)` index
  (`lib/nest/persistence.ex:281-284`, migration `20260716130200_create_messages.exs:95`), both callers
  derive the same index from the same pre-heal tail, and the loser's in-memory row matches the winner's
  `(index, role)`. The duplicate `chat:message` broadcast that remains is idempotent client-side
  (`addChatMessage` merges by `index`, `assets/js/store/slices/agentCacheMessages.js:46`).
- The heal cannot corrupt a *live* agent: `Supervisor.get_agent/2` only reaches
  `fetch_or_start_agent/2` on a Registry miss or a dead pid (`lib/nest/agents/supervisor.ex:398-424`),
  and every other caller (`create_agent/3`, `restart_agent/2`, the child-spawn paths) has no live
  agent for that name, so a mid-turn `user` tail can never be healed out from under a running turn.
- Claim "an idle agent never ends on a user message": `Turn.Commit.ensure_assistant_tail/1`
  (`lib/nest/agents/agent/turn/commit.ex:99-105`) closes the compaction segment, `Repair.classify_load/1`
  closes the load path, and the terminal paths (`Turn.Terminal.recovery_messages/2`) only ever append
  repair/partial messages — the `continuation_prompt/0` is passed as `incoming`, never appended — so
  after a stop/crash the tail is an assistant too. The live-path `{:repair, _}` clause in
  `Repair.classify_live/2` really is a last-resort guard, and it cannot fire mid-turn because
  `agent_channel.ex:313-321` rejects `chat:message` for `:streaming`/`:executing_tools`/`:compacting`/etc.
- Claim "a blocking wait never returns an empty result": `agents-query` has three distinct tagged
  errors (`tool_loop.ex:397-420`) and no path yields `{:ok, ""}` (`assistant_reply/1` maps `""` →
  `{:error, :no_text}`); `agents-spawn`'s `spawn_reply_result/4` and its existing timeout clause both
  return `is_error: true`; `agents-batch`'s `slot_to_string("")` is a marker and `assemble/3` offloads
  through `Overflow.substitute/5`; `Overflow.head_text/3`/`truncate_to_fit/3` have no default marker
  left, and every production caller passes one that names the scratch file or says the temp file was
  unavailable (`batch_sizer.ex:387-416`, `batch_loop.ex:477`, `tool_loop.ex:634`).
- `work.focus` lifetime: `Phase.enter/4` is the only phase writer, `turn_focus/3` clears on `:chat` or
  any `:idle`, and `enter_blocked/2` preserves it only for the retryable blocked exits, so the manual
  `/compact <focus>` guidance cannot leak into a later automatic compaction (`Compaction.stage/3` →
  `Dispatch.compaction_plan/1` → `compute_summary_budget/4` threading verified end to end).
- `#12`: the merged live+persisted listing really is name-ordered (`visibility.ex:57-77`), so the
  4000-char `String.slice/2` in `tool_loop.ex:281` drops the alphabetically-last agents; persisted-only
  rows resolve their slug via `vocation_slugs_by_id/0`; and the new lobby-side ordering is harmless
  because `SidebarSpaceRow.buildAgentTree` alphabetizes siblings itself.
- `#13`: the `priorBoundary` capture is taken before both `setAgentConnected/2` calls, and a boundary
  can only differ from the cached one after a compaction the client never saw (`setAgentCompaction`
  keeps them in sync otherwise), so the new `!==` branch does not cause spurious full re-syncs; the
  `chat:status` broadcast path never reaches `reconcileAgentCache` with the default `priorBoundary`.
- `#6`: the scrollbar-drag regression is fixed (`scrollTop < lastScrollTop` after the epsilon check,
  `assets/js/hooks/useScrollToBottom.js:82-87`), content growth cannot un-pin, and the
  ArrowUp/Home/PageUp/modifier guards match the documented intent; 23 hook tests pass.
- Test hygiene in the new/edited tests: no sleeps, no new `async: false`, no Logger prints outside
  `capture_log`, no `assert_receive` over 500ms other than the `2_000` noted above, and each asserted
  log line is emitted before the fence the block waits on.
- Junk sweep: no commented-out code, debug prints or new TODOs in the added lines; no stray files
  (`.nest` is now ignored at `.gitignore:51`; the only new untracked paths are the ignored
  `notes/test-runs/` logs I created).
- `a3901ae` reviewed: it is only the `priv/repo/seeds.exs` vocation-prompt addition already raised in
  the prior review and deliberately kept. The trailing space at `priv/repo/seeds.exs:240` is inside a
  heredoc, and both `mix format --check-formatted priv/repo/seeds.exs` and `mix credo
  priv/repo/seeds.exs` pass, so it is not a lint failure.
- `NestWeb.AgentChannel.Sync` is a pure move (same `@sync_size_limit`, same semantics) and
  `slashCommands.parseSlashCommand`'s new token/args split handles `/compact`, `/compact `, trailing
  whitespace, newlines and unknown commands correctly.
