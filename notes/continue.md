# CONTINUE — clone/history cleanup (branch `clone-history-cleanup`)

State: branch `clone-history-cleanup` (from `origin/main` = `b5728b7`), three commits,
`4d87795` tip. Working tree clean. `mix test`1603/0, `format` + `credo` clean.
Not pushed. This is the *nest* repo's handoff; the root `notes/continue.md` is the
DeepSeek V4 handoff and was deliberately left alone.

## Done (commits `4c98c02`, `28a30db`, `4d87795`)

- A clone forks the parent's **visible** `messages` only; `last_compaction_index` is
  inherited. (The crash: preload was `history ++ messages`, i.e. the raw shared
  sequence incl. the `{:compaction, _}` marker, re-partitioned with a runtime mirror
  that compaction never updated -> `-1` -> marker landed in the child's `messages` ->
  `AnthropicClient.message_to_wire/2` function_clause.)
- `MessageAppender.append_marker/2` (was `append_history_one/2`) stamps the marker,
  persists it (unified path: `Pagent/persistence.insert_message/3:255-272` ->
  `CompactionMarker.record/5`, one transaction with the `agents.last_compaction_index`
  bump) and moves the runtime boundary to the marker index.
- `ChatState` has no `history`. The archive is derived on demand:
  `Nest.Pagent/persistence.History.load/2`, exposed as `Persistence.load_history/2`.
 Display/audit reads resolve in the **caller** process (`Agents.build_agent_data/1`,
  `Agents.get_api_logs/3`, `api_logs_for/3` takes the archive as an argument). Ecto
  sandbox ownership enforces this: an agent GenServer querying the DB raises
  `DBConnection.OwnershipError` in tests, and a slow read would block a live turn.
- `maybe_detach_clone/1` deleted; a clone keeps its fork pointer for life;
  `fork_message_index: NULL` means root or fresh child only.
- Docs: `notes/shared-message-structure.md` D9 inverted, "detached clone" removed.

## Next: one new integer, lazy archive (agreed, not implemented)

Model: the collapsed card's numbers are derivable - earlier messages =
`last_compaction_index + 1` (indices are dense from 0; ancestor prefix fills below
`F`), and that same value is the first active index / sync lower bound. So the only
new state is **`compaction_count`**.

1. Migration: `compaction_count` (nullable int) on `messages`. Latest migration is
   `20260925171617_add_fork_message_index_to_agents.exs`; marker columns live on
   `messages` (`persisted_message.ex:107-115`, cast list `:134-137`).
2. `PersistedMessage`: `field :compaction_count, :integer` + cast.
3. `Nest.Messages.Compaction`: struct `messages/compaction.ex:31-36`, `@type :42-45`,
   `to_json :57-60`.
4. `Marker.build_marker/4` (`compaction/marker.ex:31`) it;
   `CompactionMarker.record/5` + `insert_marker/6` carry it into the row.
5. `MessageAppender.append_marker/2`: `compaction_count: state.chat_state.compaction_count + 1`.
6. `ChatState`: `compaction_count: 0`. `Init.seed_from_db/3`: compute it while
   partitioning (count `{:compaction, _}` rows with `index <= boundary in
   already-loaded list - no extra query; pins the `prepend_system/3` shift case).
7. `Agent.build_child_attrs/5`: copy it (it describes the shared sequence).
8. `agent_channel.ex:237-255` `build_init_payload/1`: drop `"history" => rows`, add
   `"lastCompactionIndex"` and `"compactionCount"`. No DB read at join.
9. New `handle_in("chat:history", ...)` -> `Agents.get_history_slice/4` resolved the
   channel process, paged (`limit`, `before`) with the predicate in SQL:
   `History.load/4` (today `load/2` is O(whole sequence) - it filters
   `load_full_messages`).
10. `assets/channels/agent.js`: store the two numbers; fetch on expand; fix the
    post-compaction resync `requestSync(agentId, {lastIndex: marker.index})` ->
    `marker.index + 1` ( marker is archived; first active row is one past it).
11.CompactionMarker.jsx`: render from the two numbers.
12. `Compaction.ResultHandler`'s `Broadcasts.compaction/3` call: marker + count, no
    archive - this removes the last in-agent DB read. `chat:compaction` keeps sending
    the *new* marker (the event's subject).

Steps 8-11 must land together (payload shape + JS). Steps 1-7 are additive and safe
alone. Tests: increments per compaction and survives restart (recount == stored);
clone inherits it; init carries no rows sync never returns a row `<= boundary`;
`chat:history` returns exactly the requested slice. First check: grep for other
readers of the archive on connect/reconnect (`sync` path, list endpoints).

Also outstanding (separate, user-requested): delete the `:pagent/persistence_enabled` flag -
`agents/agent/pagent/persistence.ex` (doc :6, gates :21/51/96, defp :111),
`agents/supervisor.ex` (:61/403/446, defp :131), `agents/agent.ex` (init gate ~:445-449
incl. `:non_pagent/persistence_not_implemented`, defp ~:547), `config/test.exs:16-22`, plus
stale comments in `test/nest/agents/agent_pagent/persistence_test.exs:6-11` and
`test/nest/agents/persisted_message_test.exs:18-19`. No test toggles the flag.
