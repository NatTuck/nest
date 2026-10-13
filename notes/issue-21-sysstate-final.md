# `:sys.get_state` — barriers and reads (issue #21, `issue-21-sysstate-final`)

Finishes the work `notes/sys-get-state-audit.md` classifies: **Goal 1** (remove
the barriers) and **Goal 3** (the reads). `SMELLS.md` untouched; no reverts; no
`git stash`.

## Counts

| quantity | before | after |
|---|---|---|
| `:sys.get_state(` in `test/` | 155 | 107 |
| `_ = :sys.get_state` hits in `test/` | 27 | 17 |
| … of those, real discards | 26 | 16 |
| `:sys.get_state(` in `lib/` | 2 | 2 (both the audit's `lib/` rows) |

The 16 remaining discards are the audit's allowlist §5.3/§5.4 (13
broadcast-nothing barriers + 3 registry-partition barriers) plus the
`refute_no_preflight_reply/1` anchor; one further hit is a comment line
(`surgical_reloader_test.exs:72`). The 107 remaining sites are 48 allowlisted
rows (audit §5) + 59 left alone below.

## Goal 1 — the 10 barriers converted

| site | was | is now |
|---|---|---|
| `agent_agents_md_test.exs:204` | discard | `assert_receive {:chat_compaction, %{marker: %{"role" => "compaction"}}}, 1_000` |
| `agent_compaction_preflight_test.exs:194` | discard + `assert_received` | `assert_receive {:chat_compaction, payload}, 1_000` |
| `agent_compaction_system_repeat_test.exs:115` | discard | `assert_receive {:chat_compaction, %{marker: …}}, 1_000` |
| `agent_compaction_test.exs:276` | discard + `assert_received` | `assert_receive {:chat_compaction, payload}, 1_000` |
| `sandbox/shell_jobs_test.exs:92` | discard | `assert_receive {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}, 1_000` (the broadcast `finish_job/3` emits *after* `remove_script/1`) |
| `agent_channel_test.exs:526` | `push_history/2`'s flush | dropped; the 8 `assert_reply …, 0` callers carry `1_000` |
| `lobby_channel/providers_test.exs:168,171` | two flushes | dropped; `assert_reply …, 1_000` and `assert_push …, 1_000` |
| `lobby_channel_archive_test.exs:401` | `push_and_settle/3`'s flush | helper deleted; the 21 `assert_reply` callers carry `1_000` |
| `lobby_channel_test.exs:280` | flush | dropped; `assert_reply ref, :ok, public, 1_000` |

The `chat:compaction` frame is emitted by `Turn.Executor.commit_active_segment/5`
*after* `append_marker/2` + `append_in_process/2`, so receiving it is a
happens-after anchor for the commit — the same thing the barrier guaranteed.
The `{:shell_jobs, …}` frame is broadcast by `finish_job/3` after
`remove_script/1`. Each fence asserts the payload that identifies its event, so
a fence that could be satisfied by other traffic fails.

### The pins

Two fence shapes were introduced, and each has a pin (a test that fails if the
fence regresses to a form that no longer decides its event):

* `agent_compaction_preflight_test.exs` — *"the fence is the commit's frame: a
  plain turn broadcasts none"*: a plain chat turn must leave no
  `{:chat_compaction, _}` behind (`refute_received`), and the commit's own frame
  must carry the marker.
* `sandbox/shell_jobs_test.exs` — *"kill broadcasts an updated job list"* now
  also pins that no `:exited` frame exists while the job is running, so a fence
  satisfied by the start broadcast fails.

The five "give the positive assertion a real bound" conversions need no pin:
the replacement *is* the deciding event with its own bound (an `assert_reply` /
`assert_push` with a non-zero timeout cannot pass without the event).

## Goal 3 — production API added

`Nest.Agents.Agent.ClientAPI` (each re-exported by `defdelegate` from
`Nest.Agents.Agent`, each with `timeout \\ 5_000`):

`get_pending_children/2` (`Machine.pending_children/1`),
`get_crossed_thresholds/2`, `get_children/2` (the raw `Machine.Children`, which
`Children.target/2` needs), `get_work/2` (`Machine.Work` — read as one value so
a caller inspecting several of its fields sees one snapshot),
`get_client_config/2`, `get_tools/2`, `get_vocation/2`, `get_watches/2`.

`Nest.Sandbox.ShellJobs.waiters/2` (a *different* GenServer, per the audit
§6.3). Every converted test site passes `1_000`.

Deliberately **not** added: `get_cancelled/2`, `get_consecutive_compaction_count/2`,
`get_context_projection/2`, `get_pending_user_message/2` — every site that reads
those fields reads another family from the same snapshot, so no clause would
serve a single-call conversion (see below).

## Goal 3 — the 39 reads converted

`agents_batch_test` 6×`pending_children` + `batch_target` + `await_message` (8)
· `agent_change_model_test` 90, 350 · `agent_chat_test` 311 ·
`agent_compaction_system_repeat_test` 439, 469 · `agent_compaction_test` 293 ·
`agent_context_limit_test` 76, 92, 113, 137, 171 · `agent_context_warning_test`
158, 202 · `idle_fence_test` 96 · `inbox_test` 222, 321, 385 ·
`turn_backgrounding_test` 601 · `watch_test` 67, 399, 435 ·
`agent_workspace_test` 281, 289 · `chat_task_crash_test` 267 ·
`sandbox/shell_jobs_test` 43 · `tools/shell_jobs_test` 44 ·
`agent_channel_chat_test` 468, 638 · `agent_channel_queued_message_test` 52, 402.

## Goal 3 — the 59 sites left alone

**The rule applied (the task's hard constraint):** one `:sys.get_state` is one
atomic snapshot, so a site that reads several fields from it must become **one**
accessor call covering all of them. Where no single accessor returns every field
a site reads, the site is left byte-identical rather than torn into two calls.
The audit's replacement column (`:get_work` *plus* `pi.status` *plus*
`get_messages/1`) assumes several calls per snapshot; that is the one place this
work deliberately departs from the audit.

**R1 — the transcript read together with another family (28).** No accessor
returns `chat_state.messages` *and* anything else.

`agents_batch_test.exs` 98 (messages + `pending_children` + `descendant_usage`),
478 (inbox + messages), 562 (`await_idle/1`: children + messages) ·
`clone_agent_flow_test.exs` 186 (messages + `descendant_usage`), 214 (depth +
messages) · `agent_compaction_test.exs` 328 (messages + status), 461 (messages +
`space_id` + `name`) · `inbox_test.exs` 41, 83, 105, 173 (messages +
`tmp_path`), 279 (messages + `owed_replies`), 393, 449, 472, 540 ·
`reply_debt_test.exs` 86, 132, 192, 247 (messages + `owed_replies`) ·
`sub_agent_query_delivery_test.exs` 136, 267 · `turn_acceptance_test.exs` 144 ·
`turn_backgrounding_test.exs` 287, 335 · `agent_channel_queued_message_test.exs`
312, 426 · `agent_workspace_test.exs` 228 · `needs_repair_test.exs` 204
(status + violations + command + messages).

**R2 — `Machine.Work` / `loop_count` / `cancelled` / `stop_timer` read together
with the status (19).** `get_work/2` covers the work set but not the status, and
`get_public_info/2` covers the status but not the work set.

`clone_agent_chat_stop_test.exs` 72 (children + work + `cancelled` + status),
220 (children + `descendant_usage` + messages) · `turn_acceptance_test.exs` 99,
267, 315, 367 · `turn_backgrounding_test.exs` 122, 186, 428, 441, 518, 627,
545 (inbox + `work.backgrounded`) · `turn_declined_delivery_test.exs` 101 ·
`agent_stop_test.exs` 327 (status + work + `cancelled` + `stop_timer`) ·
`agent_stream_error_test.exs` 100 · `chat_task_crash_test.exs` 280 ·
`agents_test.exs` 511 (status + `loop_count` + `work.focus`) ·
`agent_channel_compaction_loop_test.exs` 110 (status + `loop_count`).

**R3 — the client config read together with the model and/or status (6).**
`get_client_config/2` returns `client`; the model map and the status are
separate accessors. `agent_change_model_test.exs` 98, 158, 168, 251, 262 ·
`agent_recovery_test.exs` 90.

**R4 — one-off mixed reads (6).**
`agent_compaction_preflight_test.exs` 125 (status + `pending_user_message` +
messages) · `agent_compaction_system_repeat_test.exs` 121 (`run_compaction/3`'s
compaction-time snapshot: model + tools + vocation + messages + indices) ·
`agent_context_warning_test.exs` 114 (messages + `context_projection`) ·
`agent_workspace_test.exs` 112 (`workspace_path` + tools + messages) ·
`supervisor_spawn_test.exs` 208 (depth + tools).

Two of these are the audit's own "the same row also *asserts* on fields; the
assertion should still move to an accessor" rows (`inbox_test.exs` 345,
`agent_compaction_system_repeat_test.exs` 121): moving the assertion would add a
second read of the same snapshot, so it is left whole.

## Harness ripple (no `lib/` semantics changed)

`agents_batch_test.exs`'s `delivered_texts/2` now takes a message list;
`await_message/1` passes `Agent.get_messages/2`. The `cast_child_completed/2`
fixture's hand-rolled 11-key usage map became
`%{Broadcasts.empty_usage_totals() | output_tokens: 42, total_tokens: 42, last_output: 42}`
(same map, the repo's own idiom) because the file had to stay under the
700-line cap.
