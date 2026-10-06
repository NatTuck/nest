# Issue #8 — Handle send user message after user message (plan)

> Produced by a planning minion, read-only. Pending team-lead review. This plan is the most
> invasive of the four and includes a proposed amendment to the "repair never runs on the live
> path" invariant — read the Open Questions first.

## Goal
When the active message list ends on a `user` message and the user sends another one, insert the canonical synthetic assistant bridge before the new user message so the wire alternation stays valid and the user's message is delivered (instead of the turn dying with a `chat:error`).

---

## Root cause (evidence)

**The turn-opening user append is misclassified as a live append, so the terminal bridge never runs for it.**

1. `Machine.Transitions.start_chat/3` puts the machine into `:generating` **before** the append action is executed:
   - `lib/nest/agents/agent/machine/transitions.ex:381-384`
     ```elixir
     :fits ->
       {notice_actions, m} = user_notice_actions(m, projected)
       machine = init_turn(enter(m, :chat, :generating, :http), entry)   # phase flipped here
       {:ok, notice_actions ++ [{:append, user}, :iterate], machine}
     ```
   - `Turn.run/5` installs that machine (`put_machine`) *before* running the actions (`lib/nest/agents/agent/turn.ex:47-58`), so `{:append, user}` sees `phase: :generating`.
2. `MessageAppender.append_with_bridge/2` therefore takes the **live** branch: `lib/nest/agents/agent/message_appender.ex:177-186` (`if live_turn?(state)`, with `@live_phases [:generating, :executing_tools]` at line 71, `live_turn?/1` at line 214).
3. `Repair.classify_live/2` has no repair path for this shape: `lib/nest/agents/agent/repair.ex:76-92`. With a `user` tail, `same_wire_role?/2` (`repair.ex:170-175`) is true (`MessageList.last_wire_role/1` returns `:user` for both `{:user, _}` and `{:tool, _}` — `lib/nest/messages/message_list.ex:335-347`), so it returns `{:invalid, "repair does not run on the live path: refusing to append a second consecutive user message"}` (`repair.ex:185-189`).
4. `append_live/2` returns `{:invalid, reason, state}` without appending (`message_appender.ex:188-194`) → the executor emits `{:append_result, :invalid, reason}` (`turn/executor.ex:151-159`) → the `:generating` transition calls `fail_turn/3` (`transitions.ex:296-298`) → `chat:error` is broadcast (`executor.ex:238-268`) and the user's message is **lost**. The terminal recovery then heals the sequence with an assistant ack (`turn/terminal.ex:37-56` → `Repair.decide(:terminal, …, MessageList.continuation_prompt())` → `pairing_bridge/2` → `repair_ack/0`), which is why the agent looks "fine" afterwards.

**The bridge that would fix it already exists and is correct** — `MessageList.pairing_bridge/2`, `lib/nest/messages/message_list.ex:190-207`:
```elixir
{wire_user, _} when wire_user in [:user, :tool] ->
  if match?({:user, _}, incoming), do: [repair_ack()], else: []
```
It is simply never reached for the turn-opening append (the append is "live"), only at a terminal boundary — e.g. the compaction-resume path, which deliberately appends the held user message while the machine is still `:idle` (`lib/nest/agents/agent/machine/compaction.ex:144-159`, comment: *"Append the held user at the terminal (idle) boundary so the pairing bridge heals a summary_user -> user double role"*).

**How the state can have a `user` tail while idle (all confirmed in code):**
- Load: `Persistence.classify_sequence/2` (`lib/nest/persistence.ex:445-458`) runs `Repair.decide(:load, …)`; a trailing `user` message passes `Preflight.validate/1` (`lib/nest/llm/preflight.ex:89-107`, rules `:alternation`/`:no_trailing_orphan`) → `:ok` → agent comes up idle with a `user` tail (crash/restart between the user append and the first assistant append).
- Compaction: the committed active segment is `[system?, summary_user, carried_tail]` (`lib/nest/agents/agent/turn/commit.ex:44-58`); with no carried entry and no held user message, `Compaction.resume/1` → `resume_with_pending/1` → `{:finalize, :clean}, {:drain_inbox}` and idle (`compaction.ex:126-159`) → tail is `summary_user`.
- Offline repair inserts (`lib/nest/persistence/message_repair/planner.ex:421-431`) and any terminal-recovery append that was dropped (`executor.ex:396-410`).

**Current behavior, precisely:** a chat message onto a `user` tail works *only* when a context threshold happens to be crossed, because `build_user_notice/4` → `NoticePairInjector.build_pair(msgs, spec, :user_agent)` returns a single `[assistant(notice+ack)]` for a trailing `:user` source role (`transitions.ex:405-445`, `lib/nest/agents/agent/notice_pair_injector.ex:84-98`). That is why `test/nest/agents/agent_context_warning_test.exs:48-52` (seeds `[system, user]` via `:sys.replace_state`, then chats past 25%) passes today and masks the bug: below every threshold, the same user action produces `chat:error` and a dropped message.

**Not confirmed by execution:** the planner did not run the suite (read-only planning), so the exact pre-fix error text and dropped-message behavior are derived from the code paths above, not observed. Task 4's integration test is written to fail before the fix, which will confirm it.

---

## What the "fake agent message" should be

`MessageList.repair_ack/0` — **verbatim** (`lib/nest/messages/message_list.ex:286-304`):

- **Role:** `:assistant` (wire role `assistant`).
- **Shape/content:** `{:assistant, %Assistant{parts: [%Part.Text{text: "The previous tool call was interrupted before it finished. I'll continue from here."}], api_logs: []}}`, `index: nil` (the appender stamps the real index), `timestamp`/`usage`/`model`/`metadata` nil.
- **Why this exact message:** it is already the single canonical synthetic ack — the offline repair tool inserts the same text for a `user,user` alternation break (`planner.ex:421-431` builds `:ack` from `MessageList.repair_ack/0` at `planner.ex:532-535`; test `test/nest/persistence/message_repair/planner_test.exs:124-133`). `Repair`'s moduledoc requires all repair contexts to produce *identical* shapes, so a new wording would mean splitting the offline tool's `:ack` too. (The text mentions a tool call, which is inaccurate for the user-tail case — pre-existing; see open question 2.)
- **How it lands:** through `MessageAppender.append_stamped/2` like any other message → sanitized, index-stamped, persisted, broadcast (`message_appender.ex:220-256`), so it is real and visible.
- **UI:** rendered by `assets/js/components/Message.jsx:52-80,101-165` as a normal grey "AI" bubble containing the text (markdown), no thinking/tool parts. Its API-log widget shows the amber `API response log missing — not recorded` indicator (`assets/js/components/ApiLogsBlock.jsx:254-256`) because `expectsResponseLog` is true for any assistant message without `metadata.error`/`stopped_by_user` (`Message.jsx:160-164`). That is already the case for every existing repair ack (load heal, terminal recovery, compaction resume) — unchanged by this fix.
- **Sequence/LLM view:** `… user(prev) → assistant(bridge) → user(new) → assistant(real)`; the bridge is part of the persisted prefix and of the next request's messages.

---

## How alternation is currently enforced / repaired (map)

| Layer | Where | Behavior |
|---|---|---|
| Rule set | `lib/nest/llm/preflight.ex:30-60` | `:alternation`, `:tool_pairing`, `:no_orphan_tool_results`, `:no_trailing_orphan` |
| Live append | `message_appender.ex:188-194` + `repair.ex:76-92` | classify only; `:stale` drops, `{:invalid, _}` fails the turn loudly. **No repair.** |
| Terminal append (idle/stopping/blocked) | `message_appender.ex:180-185` → `Repair.decide(:terminal, …)` → `MessageList.pairing_bridge/2` | appends repair messages first |
| Terminal recovery (stop/crash) | `turn/terminal.ex:37-56` | same bridge with `continuation_prompt/0` |
| Worker death | `repair.ex:126-134` (`:worker_death`) | canonical error tool result |
| Load | `repair.ex:103-124`, `persistence.ex:445-458`, `init/interrupted_tool_call.ex:30-43` | lone trailing orphan → error result + `repair_ack`; else `:needs_repair` |
| Offline | `mix nest.repair_messages` → `planner.ex:421-431` | inserts `:ack` (user,user) / `:continuation` (assistant,assistant) |
| Compaction request only | `turn/dispatch.ex:179-195` | non-persisted assistant bridge when the request tail is wire-`user` |

The gap is exactly one cell: the **turn-opening user append** is classified as "live" and gets neither the live-strictness rationale nor the terminal bridge.

---

## Tasks

### Task 1 — `lib/nest/agents/agent/repair.ex`: give the `:live` decision a single, documented exception
- Widen `@type live_decision` (`repair.ex:38`) and `classify_live/2`'s spec (`repair.ex:75`) to include `{:repair, [term()]}`.
- In `classify_live/2` (`repair.ex:79-91`), split the `same_wire_role?` clause, keeping it **after** the `pending != []` clause:
  ```elixir
  pending != [] ->
    {:invalid, unanswered_tool_use_reason(incoming, pending)}

  same_wire_role?(messages, incoming) and match?({:user, _}, incoming) ->
    {:repair, MessageList.pairing_bridge(messages, incoming)}

  same_wire_role?(messages, incoming) ->
    {:invalid, consecutive_role_reason(incoming)}
  ```
- Update the `@doc` (`repair.ex:69-74`) and the `:live` bullet in the moduledoc (`repair.ex:8-14`) to state: the one repair permitted on the live path is the alternation bridge for an incoming `user` message onto a wire-`user` tail, because that append can only be the turn-opening append (the channel + `Callbacks.chat_or_drop/3` reject user messages mid-turn — `lib/nest_web/channels/agent_channel.ex:306-330`, `lib/nest/agents/agent/callbacks.ex:69-80`) and the `pending != []` clause still wins, so no synthetic `tool_result` is ever fabricated on the live path.
- **Acceptance:** `Repair.decide(:live, [user(0)], user(1))` → `{:repair, [{:assistant, %Assistant{parts: [%Part.Text{}]}}]}`; `[assistant_tool_use(0,"a")]` + user → still `{:invalid, "…live tool_use…"}`; `[user(0), assistant_text(1)]` + assistant → still `{:invalid, "second consecutive assistant"}`.

### Task 2 — `lib/nest/agents/agent/message_appender.ex`: apply the decision
- `append_live/2` (`message_appender.ex:188-194`): add `{:repair, repair} -> append_messages(state, repair ++ [message])`. Keep `append_one/2` returning `List.last(stamped)` (the requested message), so `{:append, user}` callers see no change in contract.
- Amend the "Live vs terminal" moduledoc paragraph (`message_appender.ex:33-41`) and the `@live_phases` comment (`message_appender.ex:64-70`) with the same exception rationale.
- **Acceptance:** on a `live(:streaming)` state with a `user`/`tool` tail, `append_one(state, user(...))` → `{:ok, {:user, %User{}}, state}` with the ack prepended, persisted and broadcast in order, `Preflight.validate/1 == :ok`; all other live mismatches still return `{:stale, _}` / `{:invalid, _, _}`.

### Task 3 — design docs (small, keeps the codebase self-consistent)
- `notes/enforce-mesages-seq-invariants.md` §3 ("Repair never runs on the live path") and §3's `pairing_bridge` bullet: add the turn-opening-user exception.
- `test/nest/agents/agent/wire_invariant_test.exs` moduledoc (lines 1-33) and `test/nest/agents/agent/message_append_tags_test.exs` moduledoc ("the live context classifies (no repair)"): add one sentence each.

### Task 4 — tests (see next section)

### Task 5 — verification (see below)

---

## Tests to add / update

1. **`test/nest/agents/agent/message_append_tags_test.exs`** (decision table, `describe "Repair.decide/3"`, extend the existing `:live classifies ok, stale, and invalid without repairing` test at line 35 — same setup, more assertions rather than a new single-assertion test):
   - `{:repair, [{:assistant, %Assistant{parts: [%Part.Text{text: text}]}}]} = Repair.decide(:live, [user(0)], user(1))`, `text =~ "interrupted"` (canonical `repair_ack` text).
   - wire-`user` tool tail: `{:repair, [{:assistant, _}]} = Repair.decide(:live, [assistant_tool_use(0,"a"), tool_result(1,"a")], user(2))`.
   - keep: pending `tool_use` + user → `{:invalid, reason}`, `reason =~ "live tool_use"`; assistant-after-assistant → `{:invalid, reason}`, `reason =~ "second consecutive assistant"`.

2. **`test/nest/agents/agent/append_pairing_bridge_test.exs`**:
   - Extend `adds an assistant ack before a user message appended after a wire-user tail` (line 167) so the same two seed cases also run with the machine `live(:streaming)` (the exact production shape): the returned stamped message is the **user** message; roles == `initial ++ [:assistant, :user]`; the inserted assistant's text equals `MessageList.repair_ack()`'s text; `Preflight.validate/1 == :ok`; persisted rows have the same roles/indices; and the existing idle variant keeps its assertions.
   - The existing live-path tests (`line 287`, `line 304`) already pin that other live mismatches still fail loudly — no change.

3. **`test/nest/agents/agent_chat_test.exs`** (integration, the real production path — new test in `describe "chat/2"`, line 33):
   - `start_agent()`; produce the realistic idle-with-user-tail state with `AgentTestHelpers.send_compaction_done(pid, "Summary", nil)` (leaves `[system, summary_user]` — `compaction.ex:144-159`) — or, if the helper proves awkward, seed `[system(0), user(1)]` + `next_message_index: 2` with `:sys.replace_state` as `agent_context_warning_test.exs:48-76` does. `MockClient.set_response("Done")`.
   - `Agent.chat(pid, "next question")`; then assert: `assert_receive {:chat_status, %{status: "idle"}}`; `refute_received {:chat_error, _}`; the tail roles are `[…, user(summary), assistant(ack), user(next), assistant(response)]`; the ack's text is the repair text and has **no** `metadata["context_threshold"]` (proving the bridge, not a context notice, produced it); the new user message text is `"[mode: chat]\nnext question"`; `Preflight.validate(messages) == :ok`. This test must fail before Task 1/2 (dropped message + `chat:error`).
   - No `Process.sleep`; a single `assert_receive` fence with the file's existing `500` timeout.

Coverage: the new `classify_live/2` clause and the new `append_live/2` clause are both exercised by (1) and (2); no coverage decrease. No JS change → no new vitest test.

---

## Edge cases and risks

- **No double bridge with the context-notice path.** The bridge is computed at append time from the *real* tail, and `start_chat` runs `notice_actions` before `{:append, user}` (`transitions.ex:384`), so when a notice pair already ended on an assistant the bridge is `[]`. (If the bridge were instead computed in the transition from the pre-notice list it would double up — that is why the fix lives at the append site.)
- **Tool pairing is untouched.** The `pending != []` clause still precedes the new one, so a user message arriving while a `tool_use` is unanswered still fails loudly and no synthetic `tool_result` is ever created on the live path.
- **`assistant`-after-`assistant` still fails loudly** (`same_wire_role?` clause unchanged) — the invariant keeps its teeth where the racing-worker risk is real.
- **`{:tool, _}` tail** (wire `user`, e.g. a restored tool tail) is covered by the same clause and yields the same single ack.
- **Batch path**: `handle_batch/2` keeps halting on `:stale`/`:invalid`; the `{:repair, …}` path returns `{:ok, …}`, so `append_one/2` still returns the requested message and `handle_batch/2` accumulates the repair messages.
- **Preflight projection**: `start_chat` checks fit on `messages ++ [user]`, before the bridge exists; the request gains ~20 tokens against a reserve of `max(8_192, 0.1·L)` (`PreFlight.check_messages/3`), and `append_stamped/2`'s `check_passed/2` tripwire is about `:cannot_compact`, not exactness. No change needed; note it in the commit message.
- **Loop-breaker counter**: the ack is `:assistant` → `progress_message?/1` true → `reset_consecutive/1` (same as today, the user message already did this).
- **A hypothetical mid-turn user append** (unreachable through both guards) would now be bridged instead of failing the turn. This is the invariant amendment of Task 1 and the main review question (open question 1).
- **Ack wording** is inaccurate for the user-tail case but is the established single shape; changing it would also require changing the offline planner's `:ack`.

---

## Verification steps (do not run during planning)

1. Before implementing, confirm the reproduction: add test (3), run
   `mix test test/nest/agents/agent_chat_test.exs` and read the **full** output (expect the `chat:error` / dropped-message failure).
2. `mix test test/nest/agents/agent/message_append_tags_test.exs test/nest/agents/agent/append_pairing_bridge_test.exs test/nest/agents/agent_chat_test.exs` — full output; if it is long, redirect to `notes/test-runs/<name>.log` (AGENTS.md forbids `head`/`tail`/`grep` on test output).
3. `mix test` (whole Elixir suite; must stay < 5 s) and check for unexpected log prints.
4. `mix precommit` and read the **entire** output (compile `--warnings-as-errors`, `deps.unlock --unused`, `format`, `credo`, `scripts/precommit-test.sh`, `biome ci` + `node lint-file-size.mjs`, `test --cover`, `assets.test`). Fix every warning/suggestion/log print; do not touch lint configs.
5. JS is untouched, so `cd assets && pnpm vitest run` (or `mix assets.test`) is only needed if a JS file changes — the plan requires none. If Task 3's UI observation (open question 3) is picked up, then `mix assets.test` + `mix assets.check` are required.
6. `mix format` must leave the changed files unchanged; no new public API (all touched functions are private) so no docs/exports to update.

---

## Open questions / decisions for the user

1. **Where to put the fix** — recommended: the append-time exception in `Repair`/`MessageAppender` (smallest change, single decision table, bridge derived from the real tail). Alternative if you consider "repair never runs on the live path" inviolable: have `Transitions.start_chat/3` emit the bridge as an explicit action (`Repair.decide(:terminal, messages(m) ++ notice_pair, user)`), which keeps `classify_live/2` strict but requires `user_notice_actions/2` + `build_user_notice/4` to return the post-notice projected list, and adds a second action (`{:append_many, bridge}` before `{:append, user}`). Say which you want before implementation.
2. **Ack wording** — recommended: reuse `MessageList.repair_ack/0` verbatim (identical to the offline repair tool and every other repair context). Alternative: add `MessageList.unanswered_user_ack/0` with accurate text for the user-tail case and split `pairing_bridge/2`'s `[:user, :tool]` clause; that also needs the planner's `:ack` to stay in sync and updates one assertion in `append_pairing_bridge_test.exs:49-56`.
3. **UI indicator on synthetic acks** — the amber "API response log missing — not recorded" indicator already appears for every repair ack. Out of scope here; if you want synthetic messages labelled (e.g. `metadata: %{"synthetic" => true}` + `expectsResponseLog` handling), that is a separate JS+Elixir change (note `Terminal.tag_metadata/2` overwrites assistant metadata on the recovery path, so it needs care).
4. **Coverage of the `{:tool, _}` tail variant** — recommended: include it in the same clause (one predicate, `last_wire_role/1`), as the terminal bridge already does.
5. **Dependencies on other issues** — none identified. This reuses the existing `pairing_bridge/2` machinery already used by the compaction-resume path (`compaction.ex:144-159`) and needs no change to the offline planner (`planner.ex:421-431` already inserts the same `:ack` for `user,user`). The load path (`persistence.ex:445-458`) also needs no change: a trailing `user` message is wire-valid, and the fix makes the next chat turn heal it.
