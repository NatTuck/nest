# `:sys.get_state` audit — issue #21

Scope: every `:sys.get_state` occurrence in `test/` and `lib/` on
`issue-21-sysstate-audit` (`79c0abf`, worktree `tmp/wtaudit`). **Analysis only —
no code changed by this note.** The note exists to turn "291" into a per-site
verdict and to define the **allowlist** a Credo check will enforce (sibling check:
`test/support/credo/no_drain_loops.ex`).

Line numbers are against `79c0abf` and match the reproducing command below
exactly. `:sys.replace_state` is a *different* question and is out of scope
except where noted (fixture read-backs).

---

## 1. The reproducing command

```sh
cd /home/nat/Code/nest/tmp/wtaudit

# Every occurrence, comments and prose included.
grep -rn ":sys\.get_state" test/ lib/ | wc -l          # 295  (291 test/ + 4 lib/)
grep -rn ":sys\.get_state" test/ | wc -l               # 291
grep -rn ":sys\.get_state" lib/  | wc -l               #   4

# The real call sites. A call always has an argument list; a mention in a
# comment or in prose never does (`:sys.get_state/1`, `:sys.get_state/2`).
grep -rn ":sys\.get_state(" test/ lib/ | wc -l         # 266  (264 test/ + 2 lib/)
grep -rn ":sys\.get_state(" test/ | wc -l              # 264
grep -rn ":sys\.get_state(" lib/  | wc -l              #   2

# Non-sites: comment lines (the match is preceded only by whitespace and `#`).
grep -rn ":sys\.get_state" test/ lib/ \
  | awk -F: '{b=$0; sub(/^[^:]*:[0-9]+:/,"",b); gsub(/^[ \t]+/,"",b); if (b ~ /^#/) print}' \
  | wc -l                                              #  28  (26 test/ + 2 lib/)

# The barrier-discard family (grep hits, one of which is a comment).
grep -rn "_ = :sys\.get_state" test/ | wc -l           #  27  → 26 real discards
```

**The counts, stated so they can be checked rather than asserted:**

| quantity | count |
|---|---|
| `:sys.get_state` grep hits, whole tree | 295 |
| grep hits in `test/` | 291 |
| grep hits in `lib/` | 4 |
| … of those, pure comment lines | 28 (26 `test/`, 2 `lib/`) |
| … plus one prose mention inside a `@moduledoc` | 1 (`turn_acceptance_test.exs:11`) |
| **real call sites** (`grep -rn ":sys\.get_state("`) | **266 (264 `test/`, 2 `lib/`)** |
| `_ = :sys.get_state` grep hits (the rubric's "27") | 27 |
| … of those, real discards | 26 |

The brief's "291 sites" is the grep-hit count. The audit's unit is the **call
site**: 264 in `test/`, 2 in `lib/` — **266 rows in the table**. The 29
non-sites (28 comments + 1 prose mention) are listed in §3.1 so the lint can
ignore them without a per-line allowlist entry: they are not `get_state` calls,
and the check should match on the AST, not on the text.

---

## 2. The accessor inventory, verified

`Nest.Agents.Agent.ClientAPI` (`lib/nest/agents/agent/client_api.ex`) wraps 4 of
the 10 `handle_call` clauses in
`Nest.Agents.Agent.IntrospectionHandler`; all 4 are re-exported from
`Nest.Agents.Agent` by `defdelegate` (`agent.ex:507-531`), so
`Agent.get_public_info/1` etc. are the door tests already use.

**Wrapped (verdict `A` below).** `get_public_info/1` returns, and this list is
what the replacement column means by `pi.<field>`:
`name`, `space_id`, `model`, `workspace_path`, `message_count`,
`last_compaction_index`, `compaction_count`, `status` (= `Machine.status_for/1`),
`sequence_violations` (= `live.repair.violations`), `repair_command`
(= `live.repair.command`), `vocation_id`, `vocation_slug`, `tmp_path`,
`partial`, `modes`, `default_mode`, `current_mode` (= `live.mode`),
`context_limit`, `context_limit_source`, `parent_id`, `parent_name`, `depth`,
`created_by_user_id`, `shared`, `pending_messages` (= `Inbox.serialize/1` of
`live.inbox`), `pending_message_count`, `owed_replies`
(= `Machine.owed_senders(live.machine)`), `usage`, `descendant_usage`,
`total_usage`. Plus `get_messages/1`, `get_total_usage/1`, `get_api_logs/3`.

**Orphaned (verdict `B` below)** — reachable today only as a raw
`GenServer.call(pid, :get_x)`, which is what the suite already does in the two
places it needs them (`clone_agent_chat_stop_test.exs:68`,
`agent_file_policy_test.exs:355`, `AgentTestHelpers.get_system_prompt/1`):
`:get_consecutive_compaction_count` (`live.machine.loop_count`),
`:get_messages_with_cancelled` (`{messages, live.cancelled}`),
`:get_crossed_thresholds` (`live.crossed_thresholds`),
`:get_next_index` (`chat_state.next_message_index`),
`:get_system_prompt`, `:get_pending_children`
(`Machine.pending_children(live.machine)`), `:get_read_files`
(`chat_state.read_files`).

**Documented but does not exist — flagged.** `ClientAPI`'s moduledoc advertises
`get_history/1` ("archived history (compacted-away messages plus
`{:compaction, _}` markers)"). There is no such function in `ClientAPI`, no
`:get_history` clause in `IntrospectionHandler`, and no other definition
anywhere in the tree (`grep -rn "get_history" lib/ test/` → only the moduledoc
line). The archive is fetched over the channel's `chat:history` push, backed by
`Nest.Persistence.load_history/2`. The moduledoc line is stale and should be
deleted (or the function written); it is a documentation defect, not a call-site
one.

**No accessor at all (verdict `C` / `keep` below):** the whole state struct;
`live.machine` as a struct; `live.machine.work.{active_worker, worker_ref,
backgrounded, focus}`; `live.machine.children` (the raw map — `:get_pending_children`
gives `Children.pending/1`, not the map `Children.target/2` needs);
`live.machine.pending_user_message`; `live.machine.stop_timer`; `live.cancelled`;
`live.watches`; `live.context_projection`; `tools`; `vocation`;
`client_config.client`; `Nest.Sandbox.ShellJobs`' `waiters`;
`Nest.Models`' `static_config`; `NestWeb.SurgicalReloader`'s whole state.

---

## 3. The table

One row per real call site (266 rows), in `grep` order so it can be diffed
against §1's command.

**Columns.** `class` is the rubric's class. `verdict` is the change the site
needs:

| token | meaning |
|---|---|
| `A` | **mechanical** — an existing `ClientAPI` function serves it (`pi.*`, `get_messages/1`, `get_total_usage/1`) |
| `B` | **wrapper** — an existing *unwrapped* `IntrospectionHandler` clause serves it; needs a one-line `ClientAPI` wrapper (or a raw `GenServer.call`) |
| `C` | **new accessor** — no clause exists; needs a new `handle_call` clause + wrapper |
| `D` | **event** — an existing broadcast/`assert_receive` replaces the read entirely |
| `keep` | **allowlist** — the read cannot be replaced; the reason is the written justification |
| `review` | **needs-review** — I could not settle it from the code; the reason says what decision is missing |

**Counting rule (stated so the headline numbers are reproducible):** where a
site reads several fields, its verdict is the *hardest* one it needs
(`keep` > `C` > `B` > `A`), and the reason names every field read and the
accessor for each. The headline "mechanical" number in §8 is therefore a
*lower bound*: it counts sites whose verdict is `A`, and §8 separately reports
how many rows *contain at least one* mechanically swappable read.

### 3.1 Non-sites (28 comment lines + 1 prose mention)

`agents_batch_test.exs:405`, `clone_agent_registration_test.exs:208`,
`sub_agent_query_delivery_test.exs:175`, `sub_agent_tools_test.exs:85`,
`turn_backgrounding_test.exs:538`, `agent_compaction_preflight_test.exs:191`,
`agent_compaction_test.exs:272,374,568,580`,
`agent_observability_test.exs:232,241`, `supervisor_subagent_test.exs:348`,
`supervisor_test.exs:187`, `agents_test.exs:575`,
`agent_channel_chat_stop_test.exs:32`, `agent_channel_queued_message_test.exs:245`,
`agent_channel_test.exs:178`, `lobby_channel/providers_test.exs:158`,
`lobby_channel_rescan_models_test.exs:115`, `lobby_channel_scoping_test.exs:528`,
`lobby_channel_test.exs:273`, `surgical_reloader_test.exs:72,117`,
`test/support/agent_test_lifecycle.ex:55,242`,
`lib/nest/agents/agent/batch_coordinator.ex:313`,
`lib/nest/agents/agent/turn/give_up_delivery.ex:40`.

Plus the one prose mention, which `grep` does *not* classify as a comment
because the match is not preceded only by whitespace:
`turn_acceptance_test.exs:11` — a `@moduledoc` sentence ("They use
`:sys.get_state/1` to inspect the Agent's state directly"). It is not a call
site, but it **does** need an edit when the work lands: the sentence becomes
false once that file's body is converted.

### 3.2 The rows

| site | class | verdict | replacement | reason |
|---|---|---|---|---|
| `test/nest/agents/agent/agents_batch_test.exs:82` | read-for-value | A | `get_messages/1` | transcript read for the batch tool result |
| `test/nest/agents/agent/agents_batch_test.exs:97` | read-for-value | B | `:get_pending_children` (+ `get_messages/1`, `pi.descendant_usage`) | `Machine.pending_children(live.machine) == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:146` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:179` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:201` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:219` | read-for-value | A | `get_messages/1` | confirmation tool result |
| `test/nest/agents/agent/agents_batch_test.exs:228` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:304` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:334` | read-for-value | B | `:get_pending_children` | asserts `pending_children == %{}` |
| `test/nest/agents/agent/agents_batch_test.exs:401` | read-for-value | keep | none | whole state is the *argument* to `Turn.build_ctx/1`; no accessor can serve a pure-function harness |
| `test/nest/agents/agent/agents_batch_test.exs:475` | read-for-value | A | `pi.pending_messages` + `get_messages/1` | inbox entry content + "not yet in transcript" |
| `test/nest/agents/agent/agents_batch_test.exs:504` | read-for-value | C | `:get_children` | `Children.target/2` needs the raw `machine.children` map |
| `test/nest/agents/agent/agents_batch_test.exs:540` | idle-wait | D | `{:chat_status, %{name: …, status: "idle"}}` | `Eventually.eventually` polling `status_for == :idle` **and** content; sibling `issue-21-idle-fence` rewrites it to `await_delivery/1` + the idle frame |
| `test/nest/agents/agent/agents_batch_test.exs:560` | read-for-value | C | `:get_children` (+ `get_messages/1`) | `await_idle/1`'s callers assert `machine.children == %Children{}` |
| `test/nest/agents/agent/batch_coordinator_test.exs:95` | read-for-value | keep | none | whole state is the argument to `Turn.build_ctx/1` |
| `test/nest/agents/agent/broadcasts_status_test.exs:34` | read-for-value | keep | none | the subject is `Broadcasts.status/1`, whose argument *is* the state struct |
| `test/nest/agents/agent/clone_agent_chat_stop_test.exs:72` | read-for-value | C | `:get_work` / `:get_cancelled` (+ `:get_pending_children`) | `work.active_worker`, `live.cancelled` |
| `test/nest/agents/agent/clone_agent_chat_stop_test.exs:151` | barrier-discard | keep | none | `{:chat_stopped, _}` handler broadcasts nothing after the status frame; the following child-teardown lookup has no event to wait on |
| `test/nest/agents/agent/clone_agent_chat_stop_test.exs:217` | barrier-discard | keep | none | drains the `{:child_completed, …}` cast, which broadcasts nothing |
| `test/nest/agents/agent/clone_agent_chat_stop_test.exs:220` | read-for-value | C | `:get_work` (+ `:get_pending_children`, `pi.descendant_usage`) | `work.active_worker` |
| `test/nest/agents/agent/clone_agent_flow_test.exs:144` | read-for-value | A | `get_messages/1` | transcript + indices mid-batch |
| `test/nest/agents/agent/clone_agent_flow_test.exs:186` | read-for-value | A | `get_messages/1` + `pi.descendant_usage` | transcript, notice, merged usage |
| `test/nest/agents/agent/clone_agent_flow_test.exs:214` | read-for-value | A | `get_messages/1` + `pi.depth` | clone's transcript and depth |
| `test/nest/agents/agent/clone_agent_registration_test.exs:215` | barrier-discard | keep | none | `Nest.Agents.Registry.PIDPartition0`'s link-`:EXIT` cleanup announces nothing; the barrier is the only anchor (measured: ~27% still present after the `:DOWN`) |
| `test/nest/agents/agent/inbox_test.exs:41` | read-for-value | A | `get_messages/1` + `pi.pending_messages` | delivered text + `inbox == []` |
| `test/nest/agents/agent/inbox_test.exs:69` | read-for-value | A | `pi.pending_messages` | `Enum.map(inbox, & &1.from)` |
| `test/nest/agents/agent/inbox_test.exs:81` | read-for-value | A | `pi.pending_messages` + `get_messages/1` | queue empty, combined delivery |
| `test/nest/agents/agent/inbox_test.exs:100` | read-for-value | A | `get_messages/1` + `pi.pending_messages` | bare notice text, empty queue |
| `test/nest/agents/agent/inbox_test.exs:124` | read-for-value | A | `pi.pending_messages` | last entry content |
| `test/nest/agents/agent/inbox_test.exs:166` | read-for-value | A | `get_messages/1` + `pi.tmp_path` + `pi.pending_messages` | offloaded pointer + scratch file |
| `test/nest/agents/agent/inbox_test.exs:188` | read-for-value | A | `pi.pending_messages` | `inbox == []` for a broken target |
| `test/nest/agents/agent/inbox_test.exs:212` | read-for-value | A | `pi.pending_messages` + `pi.status` | parked drain: entry shape + status |
| `test/nest/agents/agent/inbox_test.exs:240` | read-for-value | A | `pi.pending_message_count` | `length(inbox) == 100` |
| `test/nest/agents/agent/inbox_test.exs:246` | read-for-value | A | `get_messages/1` | self-delivery text |
| `test/nest/agents/agent/inbox_test.exs:274` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | peer framing + debt |
| `test/nest/agents/agent/inbox_test.exs:316` | read-for-value | A | `pi.pending_messages` + `pi.owed_replies` | queued kinds/from/mode, no debt |
| `test/nest/agents/agent/inbox_test.exs:338` | read-for-value | keep | none | the struct is the argument to `Inbox.log_lost_replies/1`; the `owed_senders == []` assertion in the same row is `pi.owed_replies` |
| `test/nest/agents/agent/inbox_test.exs:380` | read-for-value | A | `pi.status` + `pi.pending_message_count` | fabricated busy status, queued count |
| `test/nest/agents/agent/inbox_test.exs:386` | read-for-value | A | `pi.pending_messages` + `get_messages/1` | three queued human entries, no append |
| `test/nest/agents/agent/inbox_test.exs:419` | read-for-value | A | `get_messages/1` | drained metadata |
| `test/nest/agents/agent/inbox_test.exs:442` | read-for-value | A | `pi.pending_messages` + `pi.current_mode` + `get_messages/1` | idle-path mode application |
| `test/nest/agents/agent/inbox_test.exs:460` | read-for-value | A | `get_messages/1` | message count before a dropped cast |
| `test/nest/agents/agent/inbox_test.exs:463` | barrier-discard | keep | none | drains a *dropped* chat cast (broken status): no broadcast exists to wait on |
| `test/nest/agents/agent/inbox_test.exs:465` | read-for-value | A | `pi.pending_messages` + `get_messages/1` + `pi.status` | nothing queued, nothing appended |
| `test/nest/agents/agent/inbox_test.exs:501` | read-for-value | A | `pi.message_count` | `before = length(messages)` |
| `test/nest/agents/agent/inbox_test.exs:513` | read-for-value | A | `get_messages/1` | delivered modes |
| `test/nest/agents/agent/inbox_test.exs:533` | read-for-value | A | `get_messages/1` + `pi.tmp_path` | human offload pointer |
| `test/nest/agents/agent/inbox_test.exs:563` | read-for-value | A | `pi.message_count` | `before = length(messages)` |
| `test/nest/agents/agent/inbox_test.exs:573` | read-for-value | A | `get_messages/1` | appended `origin: human` metadata |
| `test/nest/agents/agent/inbox_test.exs:653` | read-for-value | A | `pi.status` | `wait_idle/1`'s verification read *behind* the `pendingMessageCount: 0` frame; the frame already decides it |
| `test/nest/agents/agent/last_message_test.exs:81` | read-for-value | A | `pi.pending_messages` | entry id + `retrieved == false` |
| `test/nest/agents/agent/last_message_test.exs:92` | read-for-value | A | `pi.pending_messages` | consumed in place (`retrieved`) |
| `test/nest/agents/agent/last_message_test.exs:119` | read-for-value | A | `pi.pending_messages` | human entry untouched |
| `test/nest/agents/agent/last_message_test.exs:145` | read-for-value | A | `pi.pending_messages` | prune-on-turn-end loop |
| `test/nest/agents/agent/last_message_test.exs:154` | read-for-value | A | `pi.pending_messages` | queue empty after the consume frame |
| `test/nest/agents/agent/needs_repair_test.exs:204` | read-for-value | A | `pi.status` + `pi.sequence_violations` + `pi.repair_command` | `:needs_repair` banner fields |
| `test/nest/agents/agent/needs_repair_test.exs:214` | barrier-discard | keep | none | drains a dropped cast in `:needs_repair`; no broadcast |
| `test/nest/agents/agent/needs_repair_test.exs:215` | read-for-value | A | `get_messages/1` | "the active list is untouched" |
| `test/nest/agents/agent/reply_debt_test.exs:69` | read-for-value | keep | none | struct is the argument to `Turn.build_ctx/1` (line 74); the debt assertion is `pi.owed_replies` |
| `test/nest/agents/agent/reply_debt_test.exs:84` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | summary landed, debt gone |
| `test/nest/agents/agent/reply_debt_test.exs:96` | read-for-value | A | `pi.owed_replies` | peer owes nothing |
| `test/nest/agents/agent/reply_debt_test.exs:125` | read-for-value | A | `pi.owed_replies` | debt set at delivery |
| `test/nest/agents/agent/reply_debt_test.exs:131` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | no reminder, debt discharged |
| `test/nest/agents/agent/reply_debt_test.exs:185` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | one reminder, then give-up |
| `test/nest/agents/agent/reply_debt_test.exs:226` | read-for-value | A | `pi.owed_replies` | debt visible at delivery |
| `test/nest/agents/agent/reply_debt_test.exs:244` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | one reminder, debt cleared |
| `test/nest/agents/agent/reply_debt_test.exs:264` | read-for-value | A | `pi.owed_replies` | peer owes nothing |
| `test/nest/agents/agent/reply_debt_test.exs:305` | read-for-value | A | `pi.owed_replies` | debt discharged despite the refused give-up |
| `test/nest/agents/agent/reply_debt_test.exs:444` | idle-wait | D | `{:chat_status, %{name: …, status: "idle"}}` | `wait_idle/1`'s `Eventually.eventually` poll; sibling `issue-21-idle-fence` replaces it with `assert_receive` on the peer's own idle frame |
| `test/nest/agents/agent/reply_debt_test.exs:491` | read-for-value | A | `get_messages/1` | `peer_texts/1` |
| `test/nest/agents/agent/sub_agent_query_delivery_test.exs:124` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | indices, debt, no duplicate |
| `test/nest/agents/agent/sub_agent_query_delivery_test.exs:153` | read-for-value | A | `pi.status` | coordinator is `:executing_tools` while the batch is parked |
| `test/nest/agents/agent/sub_agent_query_delivery_test.exs:166` | read-for-value | A | `pi.status` | still `:executing_tools` after the query is delivered |
| `test/nest/agents/agent/sub_agent_query_delivery_test.exs:239` | read-for-value | A | `get_messages/1` + `pi.owed_replies` | indices, debt, no duplicate |
| `test/nest/agents/agent/sub_agent_tools_test.exs:94` | read-for-value | A | `get_messages/1` | coordinator's spawn tool result |
| `test/nest/agents/agent/sub_agent_tools_test.exs:149` | read-for-value | A | `pi.model` | child's overridden model |
| `test/nest/agents/agent/sub_agent_tools_test.exs:183` | read-for-value | A | `get_messages/1` | unparseable-model tool result |
| `test/nest/agents/agent/sub_agent_tools_test.exs:266` | read-for-value | A | `get_messages/1` | agents-list tool result |
| `test/nest/agents/agent/sub_agent_tools_test.exs:325` | read-for-value | A | `get_messages/1` | agents-send tool result |
| `test/nest/agents/agent/sub_agent_tools_test.exs:342` | read-for-value | A | `get_messages/1` | specialist received the peer framing |
| `test/nest/agents/agent/sub_agent_tools_test.exs:389` | read-for-value | A | `get_messages/1` | missing-target tool error |
| `test/nest/agents/agent/sub_agent_tools_test.exs:431` | read-for-value | A | `get_messages/1` | agents-wait-for-idle tool result |
| `test/nest/agents/agent/timeline_emitters_test.exs:107` | read-for-value | A | `pi.context_limit` | limit the request line recorded |
| `test/nest/agents/agent/timeline_emitters_test.exs:250` | read-for-value | A | `pi.status` | `:executing_tools` while the send is parked |
| `test/nest/agents/agent/timeline_emitters_test.exs:306` | read-for-value | A | `pi.status` | `:executing_tools` while the send is parked |
| `test/nest/agents/agent/timeline_emitters_test.exs:454` | read-for-value | keep | none | struct is the argument to `Turn.settle/2` / `Broadcasts.error/4` |
| `test/nest/agents/agent/timeline_emitters_test.exs:536` | read-for-value | keep | none | struct is the argument to `Agent.Timeline.debt_changes/3` (a diff emitter harness) |
| `test/nest/agents/agent/timeline_emitters_test.exs:572` | read-for-value | keep | none | struct is the argument to `Turn.settle/2` / `Agent.Timeline.child_message/3` |
| `test/nest/agents/agent/timeline_emitters_test.exs:596` | read-for-value | keep | none | struct is the argument to the `Agent.Timeline` emitters |
| `test/nest/agents/agent/timeline_emitters_test.exs:659` | read-for-value | keep | none | struct is the argument to `Agent.Timeline.compaction_staged/3` |
| `test/nest/agents/agent/timeline_emitters_test.exs:674` | read-for-value | keep | none | struct is the argument to the `Agent.Timeline` emitters |
| `test/nest/agents/agent/tool_loop_spawn_test.exs:207` | read-for-value | A | `pi.descendant_usage` | child usage merged into the parent |
| `test/nest/agents/agent/tool_loop_spawn_test.exs:380` | read-for-value | A | `get_messages/1` | `await_delivery/1` behind the idle frame |
| `test/nest/agents/agent/tool_loop_spawn_test.exs:390` | read-for-value | A | `get_messages/1` | `parent_texts/1` |
| `test/nest/agents/agent/turn/give_up_delivery_test.exs:195` | read-for-value | A | `pi.owed_replies` | the debt that arrived in the window is still owed |
| `test/nest/agents/agent/turn/give_up_delivery_test.exs:217` | read-for-value | A | `pi.owed_replies` | self-stop leaves the debt for `terminate/2` |
| `test/nest/agents/agent/turn_acceptance_test.exs:93` | read-for-value | C | `:get_work` / `:get_cancelled` (+ `pi.status`, `get_messages/1`) | `work.active_worker`, `live.cancelled` |
| `test/nest/agents/agent/turn_acceptance_test.exs:138` | read-for-value | A | `get_messages/1` + `pi.status` | indices unique/sequential |
| `test/nest/agents/agent/turn_acceptance_test.exs:177` | read-for-value | A | `get_messages/1` | budget-reminder pair |
| `test/nest/agents/agent/turn_acceptance_test.exs:261` | read-for-value | C | `:get_work` (+ `pi.status`, `get_messages/1`) | `work.active_worker` after the final call |
| `test/nest/agents/agent/turn_acceptance_test.exs:309` | read-for-value | C | `:get_work` (+ `pi.status`) | worker cleared after `stop_chat/2` |
| `test/nest/agents/agent/turn_acceptance_test.exs:361` | read-for-value | C | `:get_work` (+ `pi.status`) | worker cleared after an HTTP crash |
| `test/nest/agents/agent/turn_acceptance_test.exs:414` | read-for-value | A | `get_messages/1` | monotonic indices across two chats |
| `test/nest/agents/agent/turn_backgrounding_test.exs:110` | read-for-value | A | `pi.status` | `:executing_tools` while parked |
| `test/nest/agents/agent/turn_backgrounding_test.exs:122` | read-for-value | B | `:get_consecutive_compaction_count` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`) | `machine.loop_count == 0` |
| `test/nest/agents/agent/turn_backgrounding_test.exs:186` | read-for-value | C | `:get_work` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`, `:get_consecutive_compaction_count`) | `work.active_worker == nil` |
| `test/nest/agents/agent/turn_backgrounding_test.exs:277` | read-for-value | A | `pi.status` | `:executing_tools` while parked |
| `test/nest/agents/agent/turn_backgrounding_test.exs:287` | read-for-value | A | `pi.status` + `pi.pending_messages` + `pi.current_mode` + `get_messages/1` | human note delivered mid-batch |
| `test/nest/agents/agent/turn_backgrounding_test.exs:335` | read-for-value | A | `pi.status` + `pi.pending_messages` + `pi.current_mode` + `get_messages/1` | mode applied at delivery |
| `test/nest/agents/agent/turn_backgrounding_test.exs:414` | read-for-value | A | `pi.status` | `:executing_tools` while parked |
| `test/nest/agents/agent/turn_backgrounding_test.exs:428` | read-for-value | C | `:get_work` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`) | `map_size(work.backgrounded) == 1` |
| `test/nest/agents/agent/turn_backgrounding_test.exs:441` | read-for-value | C | `:get_work` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`) | `work.backgrounded == %{}` |
| `test/nest/agents/agent/turn_backgrounding_test.exs:511` | read-for-value | A | `pi.status` | `:executing_tools` while parked |
| `test/nest/agents/agent/turn_backgrounding_test.exs:518` | read-for-value | C | `:get_work` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`) | `work.backgrounded` holds the aggregate |
| `test/nest/agents/agent/turn_backgrounding_test.exs:543` | idle-wait | D | three × `{:chat_status, %{name: …, status: "idle"}}` | the `Eventually.eventually` poll of `status_for/inbox/backgrounded`; sibling `issue-21-idle-fence` replaces it with one `statuses_until_idle/2` per turn |
| `test/nest/agents/agent/turn_backgrounding_test.exs:552` | read-for-value | C | `:get_work` (+ `pi.pending_messages`) | `work.backgrounded == %{}` |
| `test/nest/agents/agent/turn_backgrounding_test.exs:598` | read-for-value | A | `pi.status` | `:executing_tools` while parked |
| `test/nest/agents/agent/turn_backgrounding_test.exs:608` | read-for-value | C | `:get_work` | the backgrounded map's ref/pid/ids |
| `test/nest/agents/agent/turn_backgrounding_test.exs:630` | barrier-discard | keep | none | anchor for the `refute_received {:chat_status, _}` / `{:llm_request, …}` pair: the stop's deferred `:iterate` chain has no event to wait on |
| `test/nest/agents/agent/turn_backgrounding_test.exs:634` | read-for-value | C | `:get_work` (+ `pi.status`, `pi.pending_messages`, `get_messages/1`) | `work.backgrounded == %{}` after the stop |
| `test/nest/agents/agent/turn_backgrounding_test.exs:658` | barrier-discard | keep | none | anchor for "a late `{:tool_results, …}` appends nothing"; there is no event for an *absence* |
| `test/nest/agents/agent/turn_backgrounding_test.exs:660` | read-for-value | A | `get_messages/1` | transcript unchanged after the late result |
| `test/nest/agents/agent/turn_declined_delivery_test.exs:101` | read-for-value | C | `:get_work` (+ `pi.pending_messages`, `pi.status`, `get_messages/1`) | `work.active_worker`, `work.worker_ref`, `work.backgrounded` |
| `test/nest/agents/agent/watch_test.exs:67` | read-for-value | C | `:get_watches` | `live.watches` (incl. `satisfied`, task pid) |
| `test/nest/agents/agent/watch_test.exs:75` | read-for-value | A | `pi.status` | verification read behind the idle frame in `await_idle/1` |
| `test/nest/agents/agent/watch_test.exs:108` | read-for-value | A | `get_messages/1` | `notices/1` |
| `test/nest/agents/agent/watch_test.exs:131` | read-for-value | A | `pi.status` | the wait registered without leaving idle |
| `test/nest/agents/agent/watch_test.exs:234` | read-for-value | keep | none | struct is the argument to `Watch.stop_all/1` |
| `test/nest/agents/agent/watch_test.exs:339` | read-for-value | A | `pi.pending_messages` | no bare notice queued |
| `test/nest/agents/agent/watch_test.exs:381` | read-for-value | A | `pi.pending_messages` | fetched entry consumed |
| `test/nest/agents/agent/watch_test.exs:392` | read-for-value | A | `pi.workspace_path` + `pi.tmp_path` | `Mounts.new/2` for a real `shell-cmd` |
| `test/nest/agents/agent/watch_test.exs:428` | read-for-value | A | `pi.workspace_path` + `pi.tmp_path` | `Mounts.new/2` for a real `shell-cmd` |
| `test/nest/agents/agent/watch_test.exs:464` | read-for-value | keep | none | the machine struct is the argument to `Machine.step/2` |
| `test/nest/agents/agent_agents_md_test.exs:204` | barrier-discard | D | `assert_receive {:chat_compaction, _}` | `send_compaction_done/3` commits inline and broadcasts `chat:compaction`; the frame is the event |
| `test/nest/agents/agent_agents_md_test.exs:206` | read-for-value | A | `get_messages/1` | regenerated system message |
| `test/nest/agents/agent_change_model_test.exs:90` | read-for-value | C | `:get_client_config` (+ `pi.model`) | `client_config.client == OpenAIClient` |
| `test/nest/agents/agent_change_model_test.exs:99` | read-for-value | C | `:get_client_config` (+ `pi.model`, `pi.status`) | `client_config.client == AnthropicClient` |
| `test/nest/agents/agent_change_model_test.exs:159` | read-for-value | C | `:get_client_config` (+ `pi.model`) | busy refusal left the client alone |
| `test/nest/agents/agent_change_model_test.exs:169` | read-for-value | C | `:get_client_config` (+ `pi.model`, `pi.status`) | unchanged after `{:error, :agent_busy}` |
| `test/nest/agents/agent_change_model_test.exs:200` | read-for-value | A | `pi.model` | unknown model left the model alone |
| `test/nest/agents/agent_change_model_test.exs:205` | read-for-value | A | `pi.model` | unchanged |
| `test/nest/agents/agent_change_model_test.exs:253` | read-for-value | C | `:get_client_config` (+ `pi.status`, `pi.model`) | `:model_missing` + `RecoveryClient` |
| `test/nest/agents/agent_change_model_test.exs:264` | read-for-value | C | `:get_client_config` (+ `pi.status`, `pi.model`) | repaired to `:idle` + `AnthropicClient` |
| `test/nest/agents/agent_change_model_test.exs:309` | read-for-value | A | `pi.model` | timeout left the model alone |
| `test/nest/agents/agent_change_model_test.exs:351` | read-for-value | B | `:get_crossed_thresholds` | `crossed_thresholds` is a `MapSet` after a model change |
| `test/nest/agents/agent_chat_mode_test.exs:231` | read-for-value | A | `pi.current_mode` | initial vocation default |
| `test/nest/agents/agent_chat_mode_test.exs:238` | read-for-value | A | `pi.current_mode` | requested mode applied |
| `test/nest/agents/agent_chat_mode_test.exs:247` | read-for-value | A | `pi.current_mode` | mode is sticky |
| `test/nest/agents/agent_chat_mode_test.exs:276` | read-for-value | A | `pi.current_mode` | unknown mode falls back |
| `test/nest/agents/agent_chat_test.exs:198` | read-for-value | A | `get_messages/1` | tail roles + alternation bridge ack |
| `test/nest/agents/agent_chat_test.exs:244` | read-for-value | A | `get_messages/1` | compaction ack is the tail |
| `test/nest/agents/agent_chat_test.exs:258` | read-for-value | A | `get_messages/1` | no bridge ack needed |
| `test/nest/agents/agent_chat_test.exs:311` | read-for-value | C | `:get_vocation` | `state.vocation` — the test's own comment already asks for this clause |
| `test/nest/agents/agent_compaction_preflight_test.exs:125` | read-for-value | C | `:get_pending_user_message` (+ `pi.status`, `get_messages/1`) | `machine.pending_user_message == nil` |
| `test/nest/agents/agent_compaction_preflight_test.exs:194` | barrier-discard | D | `assert_receive {:chat_compaction, payload}` | the commit broadcasts `chat:compaction` inline; the very next line is a 0-timeout `assert_received` for that same frame |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:115` | barrier-discard | D | `assert_receive {:chat_compaction, _}` | `run_compaction/3`'s fence for the commit |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:116` | read-for-value | A | `get_messages/1` | the compaction-time snapshot |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:220` | read-for-value | A | `get_messages/1` | initial system prompt text |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:270` | read-for-value | A | `get_messages/1` | initial AGENTS.md sentinel |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:413` | read-for-value | A | `get_messages/1` | carried assistant kept its stale usage |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:442` | read-for-value | C | `:get_vocation` | `state.vocation.system_prompt` before compaction |
| `test/nest/agents/agent_compaction_system_repeat_test.exs:472` | read-for-value | C | `:get_tools` | `state.tools` before compaction |
| `test/nest/agents/agent_compaction_test.exs:276` | barrier-discard | D | `assert_receive {:chat_compaction, payload}` | the next line already asserts that frame with a 0 timeout |
| `test/nest/agents/agent_compaction_test.exs:293` | read-for-value | A | `pi.space_id` + `pi.name` | the two values the test needs to drive the DB/registry |
| `test/nest/agents/agent_compaction_test.exs:329` | read-for-value | A | `get_messages/1` | the deferred final reply landed once |
| `test/nest/agents/agent_compaction_test.exs:369` | read-for-value | keep | none | `state_before.chat_state.messages` is the payload of a fabricated `{:preflight_request, …}`; the struct is the harness |
| `test/nest/agents/agent_compaction_test.exs:462` | read-for-value | A | `get_messages/1` + `pi.space_id` + `pi.name` | post-compaction shape + history load |
| `test/nest/agents/agent_compaction_test.exs:571` | barrier-discard | keep | none | `refute_no_preflight_reply/1`: the barrier is what makes the 0-timeout `refute_receive` sound, and the point of the test is that *no* reply exists |
| `test/nest/agents/agent_compaction_test.exs:587` | read-for-value | A | `pi.status` | verification read behind the idle frame in `await_idle/1` |
| `test/nest/agents/agent_context_limit_test.exs:76` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | injected cache tier won |
| `test/nest/agents/agent_context_limit_test.exs:92` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | 128k default |
| `test/nest/agents/agent_context_limit_test.exs:113` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | provider default |
| `test/nest/agents/agent_context_limit_test.exs:137` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | per-model config wins |
| `test/nest/agents/agent_context_limit_test.exs:171` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | Olla `{:olla, N}` |
| `test/nest/agents/agent_context_warning_test.exs:114` | read-for-value | C | `:get_context_projection` (+ `get_messages/1`) | `live.context_projection == nil` |
| `test/nest/agents/agent_context_warning_test.exs:133` | read-for-value | keep | none | struct is the argument to `Executor.run_all/2` |
| `test/nest/agents/agent_context_warning_test.exs:158` | read-for-value | B | `:get_crossed_thresholds` | `:p25` persisted after firing |
| `test/nest/agents/agent_context_warning_test.exs:202` | read-for-value | B | `:get_crossed_thresholds` | cleared by `compaction_done` |
| `test/nest/agents/agent_context_warning_test.exs:269` | read-for-value | keep | none | the state is `put_in`'d and handed to `ContextReminder.highest_unannounced/3` — a pure-function harness |
| `test/nest/agents/agent_file_policy_test.exs:351` | read-for-value | A | `pi.workspace_path` | `workspace_root/1` |
| `test/nest/agents/agent_observability_test.exs:242` | read-for-value | A | `pi.context_limit` + `pi.context_limit_source` | the init push carries the wire string, not the atom |
| `test/nest/agents/agent_observability_test.exs:423` | read-for-value | A | `get_messages/1` | `chat_messages/1` behind the idle frame |
| `test/nest/agents/agent_overflow_integration_test.exs:108` | read-for-value | keep | none | struct is the argument to `render_for/1` (`SystemPrompt.compose_vocation_config/5` needs `state.vocation`) |
| `test/nest/agents/agent_overflow_integration_test.exs:125` | read-for-value | keep | none | struct is the argument to `render_for/1` |
| `test/nest/agents/agent_overflow_integration_test.exs:147` | read-for-value | keep | none | struct is the argument to `render_for/1` |
| `test/nest/agents/agent_overflow_integration_test.exs:151` | read-for-value | keep | none | struct is the argument to `render_for/1` |
| `test/nest/agents/agent_oversized_system_test.exs:80` | read-for-value | keep | none | `agent_state/1` feeds `post_turn/1`, which drives `Compaction.stage/3` + `Executor.run_all/2` with the struct |
| `test/nest/agents/agent_post_tool_call_content_test.exs:149` | read-for-value | A | `get_messages/1` | `chat_messages/1` |
| `test/nest/agents/agent_recovery_test.exs:90` | read-for-value | C | `:get_client_config` (+ `pi.status`, `pi.model`) | `:model_missing` + `RecoveryClient` |
| `test/nest/agents/agent_recovery_test.exs:125` | barrier-discard | keep | none | drains a dropped chat cast in `:model_missing`; no broadcast |
| `test/nest/agents/agent_recovery_test.exs:126` | read-for-value | A | `get_messages/1` | only the system message survives |
| `test/nest/agents/agent_stop_test.exs:109` | read-for-value | A | `get_messages/1` | no empty message; stopped-by-user ack |
| `test/nest/agents/agent_stop_test.exs:164` | read-for-value | A | `get_messages/1` | the carried tool call reached the transcript |
| `test/nest/agents/agent_stop_test.exs:327` | read-for-value | C | `:get_work` / `:get_cancelled` (+ `pi.status`) | `work.active_worker`, `stop_timer`, `live.cancelled` |
| `test/nest/agents/agent_stop_test.exs:362` | read-for-value | A | `pi.status` | forced idle |
| `test/nest/agents/agent_stream_error_test.exs:100` | read-for-value | C | `:get_work` (+ `pi.status`) | `work.active_worker == nil` |
| `test/nest/agents/agent_system_messages_test.exs:48` | read-for-value | A | `get_messages/1` | `messages[0]` is `{:system, _}` |
| `test/nest/agents/agent_system_messages_test.exs:96` | read-for-value | A | `get_messages/1` | budget-reminder pair |
| `test/nest/agents/agent_system_messages_test.exs:154` | read-for-value | A | `get_messages/1` | reminder and final response have distinct indices |
| `test/nest/agents/agent_system_messages_test.exs:243` | read-for-value | A | `get_messages/1` | both attention pairs present |
| `test/nest/agents/agent_tools_second_chance_test.exs:84` | read-for-value | A | `get_messages/1` | synthetic max-iterations tool results |
| `test/nest/agents/agent_workspace_test.exs:102` | read-for-value | A | `get_messages/1` | `system_before` snapshot |
| `test/nest/agents/agent_workspace_test.exs:112` | read-for-value | C | `:get_tools` (+ `pi.workspace_path`, `get_messages/1`) | `state.tools` rebuilt |
| `test/nest/agents/agent_workspace_test.exs:146` | read-for-value | A | `pi.workspace_path` | unchanged after a refusal |
| `test/nest/agents/agent_workspace_test.exs:168` | read-for-value | A | `pi.workspace_path` | unchanged after both refusals |
| `test/nest/agents/agent_workspace_test.exs:228` | read-for-value | A | `pi.workspace_path` + `get_messages/1` | change + notice pair |
| `test/nest/agents/agent_workspace_test.exs:244` | read-for-value | A | `pi.workspace_path` | unchanged after refusals |
| `test/nest/agents/agent_workspace_test.exs:281` | read-for-value | C | `:get_tools` | spawn tools survive the rebuild |
| `test/nest/agents/agent_workspace_test.exs:289` | read-for-value | C | `:get_tools` | spawn tools dropped at max depth |
| `test/nest/agents/agent_workspace_test.exs:309` | read-for-value | A | `pi.name` | `agent_name/1` |
| `test/nest/agents/chat_task_cleanup_test.exs:76` | read-for-value | A | `pi.status` | finalized cleanly to `:idle` |
| `test/nest/agents/chat_task_crash_test.exs:267` | read-for-value | C | `:get_work` | `work.active_worker == worker` |
| `test/nest/agents/chat_task_crash_test.exs:280` | read-for-value | C | `:get_work` (+ `pi.status`) | worker cleared after the crash |
| `test/nest/agents/chat_task_crash_test.exs:300` | read-for-value | A | `get_messages/1` | no empty assistant persisted |
| `test/nest/agents/supervisor_spawn_test.exs:61` | read-for-value | keep | none | `coordinator_state/1`'s result is the `state` argument to `Supervisor.spawn_agent_in_space/3..4` |
| `test/nest/agents/supervisor_spawn_test.exs:179` | read-for-value | A | `pi.model` | model override |
| `test/nest/agents/supervisor_spawn_test.exs:193` | read-for-value | A | `pi.model` | inherited model |
| `test/nest/agents/supervisor_spawn_test.exs:210` | read-for-value | C | `:get_tools` (+ `pi.depth`) | max-depth spawn exclusion |
| `test/nest/agents/supervisor_spawn_test.exs:303` | read-for-value | A | `pi.vocation_id` | resolved allowed vocation |
| `test/nest/agents/supervisor_subagent_test.exs:132` | read-for-value | A | `pi.model` | clone's override model |
| `test/nest/agents/supervisor_subagent_test.exs:145` | read-for-value | A | `pi.model` | clone inherits |
| `test/nest/agents/supervisor_subagent_test.exs:355` | barrier-discard | keep | none | registry partition barrier (same shape as `clone_agent_registration_test.exs:215`) |
| `test/nest/agents/supervisor_test.exs:195` | barrier-discard | keep | none | registry partition barrier; the comment records the ~27% measurement |
| `test/nest/agents_test.exs:511` | read-for-value | C | `:get_work` (+ `:get_consecutive_compaction_count`, `pi.status`) | `machine.work.focus`, `machine.loop_count` |
| `test/nest/models_test.exs:255` | fixture | keep | none | fixture read-back of the `Nest.Models` singleton's `static_config`, paired with `:sys.replace_state`; the file's subject *is* the shared singleton (see `notes/issue-21-async-audit.md`) |
| `test/nest/models_test.exs:321` | fixture | keep | none | same fixture pair in `inject_second_provider/0` |
| `test/nest/models_test.exs:392` | fixture | keep | none | same fixture pair; snapshot to restore the canonical config |
| `test/nest/sandbox/shell_jobs_test.exs:43` | read-for-value | C | `:get_waiters` | `waiters/1` reads the manager's waiter map, which no public reader exposes |
| `test/nest/sandbox/shell_jobs_test.exs:92` | barrier-discard | D | `assert_receive {:shell_jobs, %{jobs: _}}` | `finish_job/3` calls `remove_script/1` and then `broadcast/2`, so the broadcast is the happens-after event for "the script is gone" |
| `test/nest/tools/shell_jobs_test.exs:44` | read-for-value | C | `:get_waiters` | the tool's caller must not be left registered |
| `test/nest_web/channels/agent_channel_chat_stop_test.exs:36` | barrier-flush | keep | none | anchor for `refute_received %Phoenix.Socket.Message{}`: a refutation needs a happens-after anchor and there is no event to wait on |
| `test/nest_web/channels/agent_channel_chat_test.exs:468` | read-for-value | A | `pi.pending_messages` + `pi.status` | the queued human message during `:compacting` |
| `test/nest_web/channels/agent_channel_chat_test.exs:581` | read-for-value | A | `get_messages/1` | the held message landed wire-valid |
| `test/nest_web/channels/agent_channel_chat_test.exs:638` | read-for-value | C | `:get_work` | `machine.work.focus` threaded through `compact/3` |
| `test/nest_web/channels/agent_channel_compaction_loop_test.exs:110` | read-for-value | B | `:get_consecutive_compaction_count` (+ `pi.status`) | the OK click reset the loop counter |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:52` | read-for-value | A | `pi.pending_messages` + `pi.status` | queued human entries verbatim |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:91` | read-for-value | A | `pi.pending_messages` | `before` snapshot |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:97` | read-for-value | A | `pi.pending_messages` | broken status queues nothing |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:120` | read-for-value | A | `pi.pending_messages` | malformed payloads queue nothing |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:127` | read-for-value | A | `pi.pending_messages` | non-binary mode normalised to nil |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:249` | barrier-flush | keep | none | anchor for `refute_push "chat:status", %{status: "idle"}, 0` |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:298` | read-for-value | A | `get_messages/1` | the delivered/queued transcript order |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:312` | read-for-value | A | `get_messages/1` | index ordering of the drain |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:399` | barrier-flush | keep | none | anchor for `refute_push "chat:inbox", %{count: 0}, 0` |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:402` | read-for-value | A | `pi.status` + `pi.pending_messages` | parked compaction leaves the queue at 1 |
| `test/nest_web/channels/agent_channel_queued_message_test.exs:424` | read-for-value | A | `pi.pending_messages` + `pi.status` | queue cleared, idle |
| `test/nest_web/channels/agent_channel_test.exs:181` | barrier-flush | keep | none | anchor for `refute_push "chat:delta", …` (a doubled subscription is the subject) |
| `test/nest_web/channels/agent_channel_test.exs:526` | barrier-flush | D | drop the barrier; give the following `assert_reply` a real bound | `push_history/2`'s barrier exists only so its callers can use a 0-timeout `assert_reply`; the reply is a real event with a measured 130–160 ms tail |
| `test/nest_web/channels/lobby_channel/providers_test.exs:168` | barrier-flush | D | drop the barrier; `assert_reply ref, :ok, %{}, 1_000` | the barrier enables a *positive* assertion, which can carry its own bound |
| `test/nest_web/channels/lobby_channel/providers_test.exs:171` | barrier-flush | D | drop the barrier; `assert_push "providers_updated", %{…}, 1_000` | the push is the event |
| `test/nest_web/channels/lobby_channel_archive_test.exs:401` | barrier-flush | D | drop `push_and_settle/3`; give the DB-backed `:ok` assertions a real bound | the helper's whole purpose is to let callers assert with `0`. Its error-path callers (`forbidden`, `invalid_payload`, `not_found`, `space_archived`, `shared_read_only`) return before any I/O, so they need no barrier at all — the same check `notes/issue-21-async-audit.md` already ran for `providers_test` |
| `test/nest_web/channels/lobby_channel_rescan_models_test.exs:121` | barrier-flush | keep | none | `refute_no_reply/2`: the anchor for `refute_receive … , 0` |
| `test/nest_web/channels/lobby_channel_scoping_test.exs:533` | barrier-discard | keep | none | `settle/1` (30 discarding callers): it orders the channel's own post-assertion DB work so the sandbox owner can exit without Postgrex noise. The reconcile *does* push `spaces_changed`, so most call sites could move to that event; the helper cannot, because two different paths share it |
| `test/nest_web/channels/lobby_channel_test.exs:280` | barrier-flush | D | drop the barrier; `assert_reply ref, :ok, public` with a real bound | the barrier enables a positive assertion |
| `test/nest_web/surgical_reloader_test.exs:74` | read-for-value | keep | none | dev-only module with no introspection API; the read is also the barrier for `init/1`'s `{:continue, …}` |
| `test/nest_web/surgical_reloader_test.exs:92` | read-for-value | keep | none | dev-only module; the read is the barrier for the `send/2` above it |
| `test/nest_web/surgical_reloader_test.exs:101` | read-for-value | keep | none | dev-only module; barrier for the `send/2` above it |
| `test/nest_web/surgical_reloader_test.exs:119` | read-for-value | keep | none | dev-only module; barrier for the `send/2` above it |
| `test/nest_web/surgical_reloader_test.exs:132` | read-for-value | keep | none | dev-only module; barrier for the `send/2` above it |
| `test/support/agent_test_lifecycle.ex:234` | probe | keep | none (see §5.2) | `agent_status/1`: the timeout is the signal ("did not answer in 250 ms" ⇒ in flight). Previously argued justified; §5.2 recommends re-sizing rather than assuming |
| `test/support/sub_agent_tools_helpers.ex:77` | read-for-value | keep | none | `coordinator_state/1`'s result is the `state` argument to `Supervisor.spawn_agent_in_space/3` |
| `test/support/sub_agent_tools_helpers.ex:170` | idle-wait | D | `assert_receive {:chat_status, %{name: …, status: "idle"}}` | `idle?/1`'s poll; the sibling `issue-21-idle-fence` branch **deletes** this function and replaces `await_idle/1` with a frame wait |
| `test/support/sub_agent_tools_helpers.ex:196` | read-for-value | A | `get_messages/1` | `query_results/1` |
| `test/support/sub_agent_tools_helpers.ex:212` | read-for-value | A | `get_messages/1` | `agent_texts/1` |
| `lib/nest/agents/agent/turn/give_up_delivery.ex:75` | read-for-value | keep | none (see §7) | production: a bounded synchronous read of a child's debt before a stop; the expiry is reported as a lost debt |
| `lib/nest/agents/agent/turn/http_worker.ex:98` | read-for-value | review | non-blocking mailbox check, or delete (see §7) | production: a per-stream-delta `GenServer` round-trip whose 5 s expiry is read as "not cancelled" |

---

## 4. Class summary

| class | sites | notes |
|---|---|---|
| `read-for-value` | 231 | the bulk; 148 of them need only an accessor swap |
| `barrier-discard` | 17 | 16 of the 26 `_ = :sys.get_state` sites, plus `lobby_channel_scoping_test.exs:533`'s `settle/1` (whose 30 callers all discard it) |
| `barrier-flush` | 10 | `agent_channel_chat_stop_test:36`, `agent_channel_queued_message_test:249,399`, `agent_channel_test:181,526`, `providers_test:168,171`, `lobby_channel_archive_test:401`, `lobby_channel_rescan_models_test:121`, `lobby_channel_test:280` |
| `idle-wait` | 4 | `agents_batch_test:540`, `reply_debt_test:444`, `turn_backgrounding_test:543`, `sub_agent_tools_helpers:170` — all four are already rewritten on `issue-21-idle-fence` |
| `fixture` | 3 | `models_test.exs:255,321,392` (read-backs of a `:sys.replace_state` fixture) |
| `probe` | 1 | `agent_test_lifecycle.ex:234` |
| **total** | **266** | |

The remaining 10 of the 26 `_ = :sys.get_state` sites are classified
`barrier-flush` because the discarded call exists to order a following
`assert_reply`/`assert_push` rather than a `refute_*`. No row is left
unclassified, and no row is `needs-review` — one row is *verdict* `review`
(`lib/.../http_worker.ex:98`), which is a production design question, not an
uncertain classification.

Verdict counts (from the table above, by the §3 counting rule):

| verdict | sites |
|---|---|
| `A` mechanical (existing wrapped accessor) | 148 |
| `B` wrapper (existing unwrapped clause) | 12 |
| `C` new accessor | 41 |
| `D` event | 14 |
| `keep` allowlist | 50 |
| `review` | 1 |
| **total** | **266** |

---

## 5. The allowlist

Conservative: every row not listed here should fail the lint. Each entry gets a
written reason. They fall into five families.

### 5.1 Whole-state / whole-machine harness reads (23 sites)

The struct is the **argument** to a pure function under test:
`Turn.build_ctx/1`, `Turn.settle/2`, `Executor.run_all/2`,
`Compaction.stage/3`, `Machine.step/2`, `Watch.stop_all/1`,
`Agent.Timeline.*`, `Inbox.log_lost_replies/1`,
`Supervisor.spawn_agent_in_space/3`, `Broadcasts.status/1`,
`SystemPrompt.compose_vocation_config/5`, `ContextReminder.highest_unannounced/3`.

`agents_batch_test.exs:401` · `batch_coordinator_test.exs:95` ·
`broadcasts_status_test.exs:34` · `inbox_test.exs:338` ·
`reply_debt_test.exs:69` · `timeline_emitters_test.exs:454,536,572,596,659,674` ·
`watch_test.exs:234,464` · `agent_compaction_test.exs:369` ·
`agent_context_warning_test.exs:133,269` ·
`agent_overflow_integration_test.exs:108,125,147,151` ·
`agent_oversized_system_test.exs:80` · `supervisor_spawn_test.exs:61` ·
`sub_agent_tools_helpers.ex:77`

Reason: these tests are **unit tests of pure functions whose signature is the
state struct**. No accessor can serve them, and adding one that returns the whole
state would be `:sys.get_state` with a wrapper — a lint circumvention, not a
fix. Where the same row also *asserts* on fields, the assertion should still move
to an accessor (noted per row); only the struct hand-off stays.

### 5.2 The teardown probe (`agent_test_lifecycle.ex:234`)

Reason: the timeout **is** the signal — an agent that does not answer in
`@agent_probe_ms` is in flight. There is no event for "this agent is wedged", and
`stop_test_agents/0` must not block on every owned agent.

**Recommendation, not assumption.** The brief records that this site was
previously argued justified; I agree with the *shape* (a probe) and disagree with
the *number*. `250 ms` is unsized: the comment itself says the sizing probe was
unusable, and the three outcomes it conflates — busy, starved, wedged — are not
distinguished. On a loaded host a starved-but-healthy agent reads as in flight
and fails the test, which is the *opposite* direction from the old behaviour and
is a new false-failure mode (recorded in `notes/sketchy-slow-tests.md`). The
honest fix is not a bigger number: it is to make the probe **non-blocking** —
`:sys.get_status/1` (which reports `{:status, :waiting}` / `{:status, :running}`
without entering the target's loop) or a `Process.info(pid, :message_queue_len)`
+ `:current_function` read — so "cannot answer" is measured without a clock at
all. Allowlist the site; do not bless the 250 ms.

### 5.3 Barriers on handlers that broadcast nothing (13 sites)

Reason: a `refute_receive`/`refute_received` (or a read of the effect of a
message whose handler emits no frame) is only sound with a happens-after anchor.
These are **not** wall-clock waits — they are synchronous reads used as
ordering — and each has a *written* justification at the call site.

`clone_agent_chat_stop_test.exs:151,217` · `inbox_test.exs:463` ·
`needs_repair_test.exs:214` · `agent_recovery_test.exs:125` ·
`turn_backgrounding_test.exs:630,658` ·
`agent_compaction_test.exs:571` · `agent_channel_chat_stop_test.exs:36` ·
`agent_channel_queued_message_test.exs:249,399` ·
`agent_channel_test.exs:181` · `lobby_channel_rescan_models_test.exs:121`

`lobby_channel_scoping_test.exs:533` (`settle/1`) belongs here too — it orders
the channel's own post-assertion DB work. Flagged separately in the fix list as
*partially* replaceable (14 sites in this family).

### 5.4 Registry-partition barriers (3 sites)

`clone_agent_registration_test.exs:215` · `supervisor_subagent_test.exs:355` ·
`supervisor_test.exs:195`

Reason: `Nest.Agents.Registry`'s per-name cleanup runs in the partition server's
`handle_info({:EXIT, pid, _})`. It announces nothing, and the `:EXIT` is *not*
ordered by the caller's `:DOWN` (measured: ~27% of exits are still in the table
right after it). `:sys.get_state/2` on the partition is the only ordering
primitive available. **This is a real gap, not a test smell**: the registry
should broadcast the removal, or the `:DOWN` should be derived from the partition
server so it *is* ordered. Until then, allowlist.

### 5.5 Dev-only module with no introspection API (5 sites)

`surgical_reloader_test.exs:74,92,101,119,132`

Reason: `NestWeb.SurgicalReloader` is dev-only tooling with no introspection
surface; the reads are also the barriers for the `send/2` (or `{:continue, …}`)
immediately above them. Adding a `:get_state` clause to a dev-only GenServer to
satisfy a lint is worse than the lint.

### 5.6 Fixture read-backs (3 sites)

`models_test.exs:255,321,392`

Reason: class 6. The `get_state` is the read half of a `:sys.replace_state`
fixture against the process-global `Nest.Models` singleton; the file is
`async: false` precisely because that singleton *is* its subject (see
`notes/issue-21-async-audit.md`). A reader clause would be test-only API on
production code. Note the fixture question (`:sys.replace_state`) is separate and
not audited here.

### 5.7 Production (2 sites) — see §7

`lib/nest/agents/agent/turn/give_up_delivery.ex:75` → keep, with the reason
recorded in `notes/wallclock-audit.md` "Design decision 4".

`lib/nest/agents/agent/turn/http_worker.ex:98` → **not** allowlisted as-is; §7
argues it should be replaced (non-blocking mailbox check) or deleted. It is the
one `review` row in the table, and the one `lib/` site that is genuinely in the
same defect family as the test-side reads.

---

## 6. The fix list, ordered by leverage

### 6.1 Mechanical — an existing `ClientAPI` function serves it (148 sites)

The cheapest wins, and the largest. Breakdown by accessor token (a row that
reads three fields appears under three tokens, so this column sums to more than
148):

| accessor | sites | the read it replaces |
|---|---|---|
| `get_messages/1` | 72 | `chat_state.messages` |
| `pi.pending_messages` | 30 | `live.inbox` (shape change: string keys, `kind` atom→string, `human?`→`human`, plus `retrieved`) |
| `pi.status` | 26 | `Machine.status_for(live.machine)` |
| `pi.owed_replies` | 15 | `Machine.owed_senders(live.machine)` |
| `pi.model` | 8 | `state.model` |
| `pi.current_mode` | 7 | `live.mode` |
| `pi.context_limit` | 7 | `llm_metrics.context_limit` |
| `pi.workspace_path` | 7 | `state.workspace_path` |
| `pi.context_limit_source` | 6 | `llm_metrics.context_limit_source` |
| `pi.tmp_path` | 4 | `state.tmp_path` |
| `pi.name` | 3 | `state.name` |
| `pi.descendant_usage` | 2 | `llm_metrics.descendant_usage` |
| `pi.pending_message_count` | 2 | `length(live.inbox)` |
| `pi.message_count` | 2 | `length(chat_state.messages)` |
| `pi.space_id` | 2 | `state.space_id` |
| `pi.depth` · `pi.sequence_violations` · `pi.repair_command` · `pi.vocation_id` | 1 each | `state.*` |

**108 of the 148 rows are *purely* mechanical** — every field they read already
has an accessor, so they need no production change at all. Those are the ones to
do first.

Two caveats worth writing down before anyone starts:

* `pi.pending_messages` is `Inbox.serialize/1`, which stringifies `kind` and
  renames `human?`. Roughly 20 of the inbox assertions destructure
  `%{kind: :user, retrieved: false}` and will need their patterns updated. That is
  mechanical, but it is not a pure find-and-replace, and it *is* a
  readability regression for the queue tests (the internal atom keys are the
  honest shape). An alternative worth considering: add `:get_inbox/1` returning
  the raw entries, and use `pi.pending_messages` only where the wire shape is
  what is under test.
* `pi.status` reads are *often redundant* with an idle frame the test has already
  consumed (`wait_idle/1`, `await_idle/1`). Deleting the read is better than
  swapping it: it is a verification of the frame, not an observation.

### 6.2 Needs a wrapper for an existing clause (12 sites)

Add 7 one-line `ClientAPI` functions (and `defdelegate`s) — the clauses already
exist and three of them are already called raw from tests, so this is pure API
surface:

| new wrapper | clause | sites |
|---|---|---|
| `get_pending_children/1` | `:get_pending_children` | 7 |
| `get_crossed_thresholds/1` | `:get_crossed_thresholds` | 3 |
| `get_consecutive_compaction_count/1` | `:get_consecutive_compaction_count` | 2 |
| `get_read_files/1` | `:get_read_files` | 0 (`agent_file_policy_test.exs:355` already calls it raw — the wrapper is for the allowlist's benefit) |
| `get_next_index/1` | `:get_next_index` | 0 (unused) |
| `get_system_prompt/1` | `:get_system_prompt` | 0 (`AgentTestHelpers.get_system_prompt/1` already calls it raw) |
| `get_messages_with_cancelled/1` | `:get_messages_with_cancelled` | 0 (unused) |

Also delete the stale `get_history/1` line from `ClientAPI`'s moduledoc (§2).

### 6.3 Needs a new accessor (41 sites)

Ranked by how many sites it unblocks, with the smallest honest clause that serves
them (again, a row needing several appears under each):

| proposed clause | sites | what it returns |
|---|---|---|
| `:get_work` | 20 | `live.machine.work` — or, better, the four fields separately: `:get_active_worker`, `:get_backgrounded`, `:get_focus` (the whole `work` struct is a machine internal) |
| `:get_client_config` | 7 | `client_config.client` only (every site asserts exactly that) |
| `:get_tools` | 5 | `state.tools` (a name list is enough: every call site does `Enum.any?(tools, &(&1.name == …))`) |
| `:get_cancelled` | 3 | `live.cancelled` |
| `:get_children` | 2 | `live.machine.children` (the raw map `Children.target/2` needs) |
| `:get_vocation` | 2 | `state.vocation` (`agent_chat_test.exs:311` already asks for it in a comment) |
| `:get_waiters` | 2 | `Nest.Sandbox.ShellJobs`' waiter map — a *different* GenServer, so this is a `ShellJobs` reader, not an agent clause |
| `:get_watches` | 1 | `live.watches` |
| `:get_pending_user_message` | 1 | `live.machine.pending_user_message` |
| `:get_context_projection` | 1 | `live.context_projection` |

(`:get_pending_children` and `:get_consecutive_compaction_count` also appear in
some `C` rows, but the clauses exist — those rows are `B`, counted in §6.2.)

**Cheaper alternatives for two of these.** `:get_tools` and `:get_client_config`
exist only because `get_public_info/1` omits them; adding `tools` (name list) and
`client` (module) to the public info map would collapse 12 rows into `A` at the
cost of two more wire fields — but the wire cost is real (`tools` is a list of
closure names, `client` is an internal module atom the UI has no use for).
Prefer the dedicated clauses. Conversely, `:get_children`, `:get_watches` and
`:get_work` expose machine internals whose *shape* is not a contract; exposing
them widens the API in a way that will ossify. For those three, a defensible
alternative is to allowlist the read with a reason ("the sub-machine's map is the
observable under test") rather than to add clauses. I have marked them `C` above
because the brief's standard is "anything not on the allowlist fails lint" —
allowlisting is the fallback, not the default.

### 6.4 Needs an event (14 sites)

| event | sites | note |
|---|---|---|
| `{:chat_status, %{name: …, status: "idle"}}` (the agent's own idle frame) | 4 | **already implemented on `issue-21-idle-fence`** — `agents_batch_test:540`, `reply_debt_test:444`, `turn_backgrounding_test:543`, `sub_agent_tools_helpers:170`. Do not re-do; coordinate. |
| `{:chat_compaction, payload}` | 4 | `agent_agents_md_test:204`, `agent_compaction_preflight_test:194`, `agent_compaction_system_repeat_test:115`, `agent_compaction_test:276` — all four already assert that frame with a 0-timeout `assert_received` on the next line; promote the assertion and delete the barrier |
| the assertion's own bound (`assert_reply`/`assert_push` with a real timeout) | 5 | `agent_channel_test:526`, `providers_test:168,171`, `lobby_channel_archive_test:401`, `lobby_channel_test:280` — these barriers exist *only* so a positive assertion can use a `0` timeout |
| `{:shell_jobs, %{jobs: _}}` | 1 | `sandbox/shell_jobs_test:92` — `finish_job/3` broadcasts after `remove_script/1`, so the broadcast is the happens-after event |

One more deletion, which is *not* an event but belongs in the same edit: three
`A` rows are **redundant status verifications** of an idle frame the test has
already consumed — `inbox_test:653`, `agent_compaction_test:587`,
`watch_test:75`. Delete the read rather than swapping it for `pi.status`.

### 6.5 Needs a new event that does not exist yet

1. **`ShellJobs.drop_agent/2` notifies nobody** (`lib/nest/sandbox/shell_jobs.ex:437`).
   Already reported in `notes/wallclock-audit.md` (Gap 1): it drops the waiters
   without sending anything, so a `shell-wait` on a job whose owner died waits out
   its whole timeout. A `{:shell_job_gone, id}` to each waiter plus a
   `{:shell_jobs, …}` broadcast fixes that consumer. It is *not* what makes the
   two `waiters/1` reads necessary — those are a plain accessor gap (§6.3) — but
   it is the same missing-event family.
2. **The child-teardown completion of `{:chat_stopped, _}`.** The handler settles
   the stop (which broadcasts a status frame) and *then* calls
   `SubAgent.stop_pending_children/1`; nothing announces when that finishes.
   Affects `clone_agent_chat_stop_test.exs:151` (and, indirectly, the `eventually`
   that follows it). A `{:chat_children_stopped, _}` frame, or moving the
   teardown to a monitor-ordered path, would remove the barrier.
3. **The stop's deferred `:iterate` / `:stop_timer` chain.**
   `turn_backgrounding_test.exs:630` refutes a status frame that could only come
   from the deferred chain; there is no frame that says "the chain is done". A
   terminal `{:chat_stopped, _}`-shaped broadcast (or reusing the machine's own
   `:idle` transition event *after* the chain) would remove it.
4. **`work.backgrounded` has no frame of its own.** Six `C` rows read it. It is
   set and cleared inside the settle, so the idle frame *is* ordered after it —
   the rows could be reduced to "read the backgrounded set behind the idle frame"
   rather than needing a new event, but there is no frame that reports the set
   itself.
5. **The registry partition's name removal** (§5.4). A broadcast on removal, or
   making the `:DOWN` the partition's own, would delete three allowlist entries.

---

## 7. The `lib/` sites

Two call sites; the other two `lib/` grep hits are comments
(`batch_coordinator.ex:313`, `give_up_delivery.ex:40`).

**`lib/nest/agents/agent/turn/give_up_delivery.ex:75` — `read-for-value`, keep.**
`state = :sys.get_state(pid, @state_timeout)` reads the child's owed senders
before the stop, so the peers it owes can be told. Constraints are genuinely
different from a test's: (a) it is a *synchronous read of state*, not a wait for
a state to settle, so it is not the wall-clock pattern; (b) the child is about to
be stopped, so no event can be arranged; (c) the expiry is *reported* — the
child's `terminate/2` logs the loss — so a bounded failure is an honest outcome,
not a silent one. The only real question is cost, and it is already recorded in
`notes/wallclock-audit.md` (design decision 4): the read is bounded at 1 s but the
*loop* over pending children is not, so a stop can take 1 s per wedged child. Fix
the loop's bound, not the read.

**`lib/nest/agents/agent/turn/http_worker.ex:98` — `read-for-value`, needs-review.**
`check_should_stop?/1` is the `should_stop` callback `LLM.Runner` consults between
every stream event, implemented as `:sys.get_state(agent_pid)` with
`GenServer`'s default 5 s bound, whose expiry is caught and read as "not
cancelled". Two problems, both wall-clock-shaped and both already written up in
`notes/wallclock-audit.md` (design decision 5):

* the *decision* depends on elapsed time — an agent busy for more than 5 s makes
  the worker decide the turn was **not** cancelled and keep streaming;
* it is a barrier on **every delta**, so the streaming worker synchronises with
  the agent's mailbox per event (this is the one `lib/` site that is genuinely
  part of the same defect family as the test-side reads).

It is not allowlistable as-is. Two honest forms, both design decisions rather
than patches: (i) make it non-blocking — the worker checks its own mailbox with
`after 0` for the `{:stop_chat, _}` the `StreamConsumer` already matches, and the
cross-process read goes away; or (ii) delete it, if the cooperative path is not a
contract — but `MockClient` (and therefore the whole test suite) has *only* that
interrupt, so deleting it changes what the tests exercise. Recommend (i). Note
that either way `Machine.Stopping.worker_kills/1` already kills the worker, so
this is a belt to that braces.

---

## 8. Headline numbers

* **266 real call sites** (264 `test/`, 2 `lib/`) — from 295 grep hits, of which
  29 are non-sites (28 comment lines + 1 `@moduledoc` prose mention).
* **148 sites are mechanical accessor swaps** (`A`); **108 of those are *purely*
  mechanical** (every field they read already has an accessor), so they need no
  production change at all.
* **12 sites need a wrapper** for an `IntrospectionHandler` clause that already
  exists (`B`) — 7 one-line `ClientAPI` functions, 3 of which are already called
  raw from tests.
* **41 sites need a new accessor** (`C`), served by ~10 new clauses; the two
  biggest are `:get_work` (20) and `:get_client_config` (7).
* **14 sites need an event** (`D`): 4 of them are already done on
  `issue-21-idle-fence`, 4 are `chat_compaction` promotions, 5 are "give the
  positive assertion a real bound", 1 is the `shell_jobs` broadcast. Separately,
  3 of the `A` rows should be *deleted* rather than swapped (redundant status
  verifications).
* **50 sites are allowlisted** (`keep`), in five families (§5): 23 harness reads,
  1 probe, 14 barriers, 3 registry barriers, 5 dev-only, 3 fixtures, 1
  production.
* **1 site left as `needs-review`**: `lib/nest/agents/agent/turn/http_worker.ex:98`
  (a production design decision, not an uncertain classification). **No test-site
  row is `needs-review`** — every test row is classified from its surrounding
  test, and where a row's *replacement* is a judgement call (the three
  machine-internal `C`s) the row says so rather than guessing.

### Things this audit did not do

* No code changed. The only file written is this note.
* No suite run, no `mix credo`, no `mix format` (no `.ex`/`.exs` touched).
* `SMELLS.md` untouched; no `git stash`; no reverts.

### Collision note for the sibling branches

`issue-21-idle-fence` (`9c47ee0`) touches exactly four of these sites —
`agents_batch_test.exs:540`, `reply_debt_test.exs:444`,
`turn_backgrounding_test.exs:543`, `sub_agent_tools_helpers.ex:170` — plus
`agent_turn_test_helpers.ex` (no `get_state`). Those four are marked `D` above and
must **not** be re-fixed by the sysstate work. `issue-21-wallclock-sites` and the
`lib/` design decisions in `notes/wallclock-audit.md` own the two `lib/` sites.
