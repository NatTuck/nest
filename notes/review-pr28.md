# PR #28 review — `boundary-delivery` (`703bad5`, `233c350`), whole-artifact pass

Reviewer: `review-pr28`. Scope: `git diff b726045..HEAD` read in full, both commits read
individually, the design note and the three committed per-part reviews' *claims* checked
against the code (their findings are not re-litigated), and the PR body verified claim by
claim. Targeted test files run; two throwaway probes written outside the repo and run
against it. Nothing in the repo was modified except this file; no stash, no revert, no
commit, no branch change.

## Verdict

**No blocker.** The two commits compose. I could not construct a reachable path where a
queued message is lost, duplicated or reordered across the machine boundary / human-queue
seam, and I confirmed the full channel → queue → drain → append → broadcast path end to end
with a probe (§ "What I tried to break").

Two **should-fix** items, both about *evidence* rather than behaviour: a new client branch
reads a wire field the server never puts on that event (so the branch, its test and a
PR-body claim are inert), and no test covers the composed channel → drain path (each half
is covered, the seam is not). The rest are nits.

## What I ran

| run | result |
| --- | --- |
| `mix test test/nest/agents/agent/machine_boundary_delivery_test.exs test/nest/agents/agent/inbox_test.exs test/nest/agents/agent/turn/executor_test.exs` | 57 tests, 0 failures (`notes/test-runs/pr28-a.log`) |
| `mix test test/nest/agents/agent/turn_acceptance_test.exs test/nest_web/channels/agent_channel_queued_message_test.exs test/nest_web/channels/agent_channel_chat_test.exs test/nest/agents/agent/machine_test.exs test/nest/agents/agent/needs_repair_test.exs` | 79 tests, 0 failures (`notes/test-runs/pr28-b.log`) |
| probe 1 (`/tmp/pr28_seam_test.exs`): channel push at a genuinely parked tool batch → queue → boundary drain → append → broadcast | passes (`notes/test-runs/pr28-seam.log`) |
| probe 2 (`/tmp/pr28_stop_test.exs`): message queued during `:stopping` | passes (`notes/test-runs/pr28-stop.log`) |
| `cd assets && pnpm vitest run --no-color js/store/index.test.js js/channels.test.js js/components/InboxPanel.test.jsx js/components/ChatInput.test.jsx js/pages/ChatPage.test.jsx` | 517 tests, 0 failures (`notes/test-runs/pr28-js.log`) |
| read `notes/test-runs/precommit-D.log` in full (1530 lines) | every number in the PR body's "Verification" section checks out |

## Findings

### 1. should-fix — `pendingMessageCount` is never on the `chat:status` **broadcast**, so the new client branch, its test and a PR-body claim are inert

* `assets/js/channels/agent.js:56-60` — new `statusExtras` branch:
  `if (payload.pendingMessageCount !== undefined) extra.pendingMessageCount = ...`, with the
  comment "The queued-message count rides `chat:status` too, so a missed `chat:inbox`
  broadcast does not leave the panel's count stale."
* `assets/js/channels.test.js:2494-2518` — the test that feeds `statusExtras` a
  `chat:status` payload carrying `pendingMessageCount: 2`.
* PR body: "the wire payloads the client now depends on (`chat:inbox` entries with
  `kind`/`mode`/`from`/verbatim `content`, `pendingMessageCount` from `chat:status`)".

**What is wrong.** `statusExtras` is only reachable from the `chat:status` *broadcast*
handler (`assets/js/channels/agent.js:357-366`) and the `needs_repair` broadcast
(`:107`). The broadcast payload is built by `Broadcasts.status_payload/1`
(`lib/nest/agents/agent/broadcasts.ex:324-353`), which carries `status`, `currentMode`,
`model`, `workspacePath`, `contextLimit`, `contextLimitSource`, `parentId`, `parentName`,
`depth`, `usage`, `descendantUsage`, `totalUsage` — **no `pendingMessageCount`**. The only
producers of that key are `IntrospectionHandler.build_public_info/1`
(`lib/nest/agents/agent/introspection_handler.ex:273`) and the channel's `init` /
`chat:status` *reply* (`lib/nest_web/channels/agent_channel.ex:286,472`); both are consumed
by `setAgentConnected` (`assets/js/store/slices/agentCache.js:184-187`), not by
`statusExtras`. `Broadcasts.NeedsRepair`/`ModelMissing` payloads do not carry it either.

**Reproduction.** `grep -rn pendingMessageCount lib/` returns exactly four sites: the
introspection info map, `Agents.get_info`, and the two channel payload builders — none of
them a `Phoenix.PubSub.broadcast`. So the stated rationale is false: a `chat:inbox` frame
that a client somehow missed is **not** repaired by the next `chat:status` broadcast (only
by a rejoin / `chat:status` request-reply). The test at `channels.test.js:2494` exercises a
payload shape the server cannot emit on that event, which is why it passes while the
feature is inert.

**Minimal fix (one line).** Put the count on the broadcast next to `currentMode`, which is
already the precedent for "the status payload carries UI state that no other event owns":

```elixir
# lib/nest/agents/agent/broadcasts.ex, status_payload/1 (next to line 330)
currentMode: state.live.mode,
pendingMessageCount: length(state.live.inbox),
```

That makes `statusExtras`, its comment and its test real, and also gives the client a
recovery path for the `:drain_inbox` empty-inbox frame. (Alternative: delete the branch +
test and correct the comment and the PR body — but the "missed frame" rationale is a
reasonable thing to want, so the one-liner is the better fix.)

### 2. should-fix — no test covers the composed channel → queue → drain → append → broadcast path

* `test/nest_web/channels/agent_channel_queued_message_test.exs` asserts the *queue* side
  (entry shape, `kind`/`mode`/`from`, `chat:inbox`/`chat:status` counts) against a
  **fabricated** status (`set_status/2` → `Machine.status_to_machine/2`) and then resets to
  idle — the queued entry is discarded, never drained.
* `test/nest_web/channels/agent_channel_chat_test.exs` (the `:compacting` case) does the
  same.
* `test/nest/agents/agent/turn_acceptance_test.exs` ("1.1.9", "1.1.10") drives the *drain*
  side through `Agent.chat(pid, content, mode, sender)` — it never goes through
  `AgentChannel.handle_in("chat:message", ...)`.

So nothing asserts that the channel's `sender`/`mode`/verbatim `content` survive into the
drain, that the delivered combined message is broadcast as `chat:message` (the payload the
client's transcript depends on), or that the queue is emptied exactly once. A regression in
either half's interface (e.g. the channel dropping `sender`, or the drain's mode resolution
changing the delivered prefix) would pass the whole suite.

**Minimal fix.** One test in `agent_channel_queued_message_test.exs`: park a real tool batch
with the `Mimic.stub(Nest.Agents, :send_message, ...)` release-valve trick from
`turn_acceptance_test.exs:536-560`, `push(socket, "chat:message", %{"content" => ...,
"mode" => ...})`, release, then assert the delivered `chat:message` payload and the
transcript (index order, `[Message from the user "<username>"]` framing, the bridge ack).

**Caution for whoever writes it** (this bit me): the channel test helper double-subscribes
the test process — `AgentTestHelpers.start_agent/1` subscribes the test pid
(`test/support/agent_test_helpers.ex:227`) *and* `subscribe_and_join/4` subscribes it to the
same topic — so every broadcast is delivered **twice**. An exact status-sequence assertion
at the channel level sees duplicates; my probe observed
`["streaming","streaming","executing_tools","executing_tools","streaming","streaming","idle"]`.
Assert on the transcript/payload, not on an exact status list. (Pre-existing helper
behaviour, not this PR's; worth knowing because the PR's new tests deliberately avoid
status-sequence assertions.)

### 3. nit — the design note (commit 1) and the implementation (commit 2) disagree about which optimistic row is retracted

`notes/issue-15-boundary-delivery.md` (committed with `703bad5`) says:

> `setAgentInbox` retracts the **oldest** still-present optimistic row whose content matches
> a user-sourced entry

`assets/js/store/slices/agentCacheMessages.js:206-215` (committed with `233c350`) scans
`for (let i = rows.length - 1; i >= 0; i--)` and therefore retracts the **newest** matching
row, and its docstring argues that newest is the correct choice ("an older matching row may
belong to a send whose `chat:message` is still in flight"), which the tests
(`assets/js/store/index.test.js`, "pairs each queued user entry with the newest matching
optimistic row") pin. The code is right and the note is stale — exactly the kind of thing
that falls in the seam between the two commits. Fix: correct the note (one word) so a future
reader does not "fix" the code back.

### 4. nit — two factual errors in the same design note

* `notes/issue-15-boundary-delivery.md:333` cites `agents-wait` (`Agent.WaitLoop`) as the
  other idle-based wait. `grep -rn WaitLoop lib/` → nothing; the module does not exist in
  this branch (it belongs to #17's `async-messages`). A committed design record should not
  reference a non-existent module without saying it is future work.
* `:325` says "`Turn.Commit` puts the pair at the **head** of the new segment". It appends
  it: `Turn.Commit.append_entry_tail/2` (`lib/nest/agents/agent/turn/commit.ex:78-82`)
  returns `new_messages ++ [a, b]`, i.e. the pair lands at the *end* of
  `[rebuilt_system, summary_user, a, b]`. The substantive claim (the `context-compact`
  resume tail is the synthetic tool result, so `iterate/1`'s `[]` branch is reached and the
  drain fires) is correct — I verified it against `Response.compact_only/5` (appends
  neither carried message) and `Commit.append_entry_tail/2`.

### 5. nit — the `{:chat, content}` / `{:chat, content, mode}` casts were removed and `Callbacks` has no catch-all `handle_cast`

`lib/nest/agents/agent/callbacks.ex:65` is now the only chat-cast clause
(`{:chat, content, mode, sender}`); the two 2-/3-tuple clauses are gone, and `Callbacks` has
**no** catch-all `handle_cast` (only the five specific clauses, then the file ends), so an
unmatched cast raises `FunctionClauseError` in the agent process. Every in-repo caller is
fine (`Agent.chat/4` always casts the 4-tuple — `lib/nest/agents/agent/agent.ex:396`;
`Agents.chat/5` defaults `mode`/`sender` to `nil`), so this is latent, not broken. But the
old clauses existed precisely as defence-in-depth for an older shape, and the module docs
still show `Agent.chat(pid, content, mode)`; an out-of-tree caller (an IEx session, a
script, a copy of the old docs) now crashes the agent instead of being dropped. Minimal fix:
either keep `def handle_cast({:chat, content, mode}, state), do:
chat_or_queue(state, content, mode, nil)` as a compatibility clause, or accept the loud
crash (consistent with the project's "crash clearly rather than hide") and say so in a
comment.

### 6. nit — two human messages with different modes: one mode wins, and the *older* message runs with caps it did not ask for

Priority-1 scenario "two human messages with different modes". `Inbox.drain_mode/1`
(`lib/nest/agents/agent/inbox.ex:158-168`) takes the most recent `kind: :user` mode and
`Executor.applied_mode/2` (`lib/nest/agents/agent/turn/executor.ex:389-405`) applies it to
the whole combined message, so the batch `["read this file" (plan), "now rewrite it"
(build)]` is delivered as one message prefixed `[mode: build]` — the `plan` request executes
with `build` caps, and the LLM cannot tell (one `[mode: X]` prefix for the whole text; only
the inbox panel shows the per-entry mode). This is documented as "the most recent human
entry with a mode wins", so it is a decision, not a bug — but the *escalation direction*
(an older message can run with more capability than its sender asked for, and the reverse
order can make an older `build` request fail under `plan` caps) is not stated anywhere.
Minimal fix: one sentence in `Inbox`'s "One mode per delivery" section, and/or an issue.

### 7. nit — three committed note files are referenced by nothing

`notes/task-c-report.md` (190 lines), `notes/task-d1-report.md` (432), `notes/task-d2-report.md`
(480) are committed with the branch but referenced by neither the PR body nor any other
committed file; the three `notes/review-*.md` files that *are* referenced restate their
content. Committing 1100 lines of duplicated process record makes the artifact harder to
review for no gain; consider dropping the task reports (or referencing them from the PR
body).

### 8. nit — the verification evidence the PR body points at is gitignored

The PR body says "The full log is `notes/test-runs/precommit-D.log`". `notes/test-runs/` is
in `.gitignore:14`, so the log is not part of the branch and cannot be checked by a reviewer
or CI — the claim is only reproducible by re-running `mix precommit` on this exact tree.
(The numbers themselves are accurate: I read the full log — credo "406 source files",
"4049 mods/funs, found no issues"; Elixir "1943 tests, 0 failures", "Finished in 3.6
seconds"; `[TOTAL] 85.1%`; biome "Checked 157 files … No fixes applied"; "OK: no source file
exceeds 500 code lines or 700 total lines"; JS "Test Files 60 passed", "Tests 1182 passed";
`exit=0`.)

### 9. observation — the human's delivered bubble shows the LLM framing (by design, but worth knowing)

After the drain, the human's own row is the *combined* message: my probe's `chat:message`
payload was

```
index 5, mode "chat",
parts: [%{kind: "text", text: "[mode: chat]\n[Message from the user \"agent-channel-tester\"]\nhuman note\n\n[Message from agent \"agent18826\"]\npeer note"}]
```

`Message.jsx:137-147` strips only the `[mode: X]\n` prefix, so the bubble renders
`[Message from the user "agent-channel-tester"]` and the batched peer message inside the
human's own bubble. That is exactly what the LLM saw, so it is consistent with the
"UI transparency" rule and with how an `agents-send` drain already renders — flagging it
only because the PR body says a queued message "is rendered from `chat:inbox` rather than
left as an optimistic bubble", and after the drain the transcript no longer distinguishes
the human's own contribution from a peer's.

### 10. observation — the mid-turn mode publish can move the user's selector while they type

`Executor.execute({:drain_inbox}, …)` now calls `Broadcasts.status(state)` when the drained
mode differs (`lib/nest/agents/agent/turn/executor.ex:306-330`), and `ChatPage`'s effect
(`assets/js/pages/ChatPage.jsx:271-279`) mirrors `cache.currentMode` into the local selector
state. So: queue a message in `plan` while the agent is busy, then pick `chat` in the
dropdown for your *next* message; when the drain lands, the selector snaps back to `plan`
mid-turn. The snap-back is inevitable under "the server's mode is the source of truth" (it
would also happen at the turn end), so this is a consequence of the deliberate publish, not
a defect — but it is a new mid-turn visible state change and the PR body only presents the
publish as a fix for a lagging selector.

## What I tried to break, and why it held

Each item names the construction I attempted and the reason it held (all verified by reading
the code paths, and 1–4 additionally by running probes).

1. **Human message queued while a peer's `agents-send` is also queued (order, mode, combined
   text).** Held. `put_entry/5` appends (`inbox ++ [entry]`), `combine/1` joins in arrival
   order, `label/1` tags per kind. Probe 1 produced
   `[Message from the user "agent-channel-tester"]\nhuman note\n\n[Message from agent
   "agent18826"]\npeer note` in that order with the human's text first, matching the queue
   order (the human's push landed before the tool batch released the `agents-send`). The
   pre-existing 1.1.10 test covers the human-then-peer order; my probe covers the same
   through the channel.
2. **A human message arriving in the same settle as a boundary drain.** Cannot be
   constructed: `chat_or_queue/4` runs in the agent process (`handle_cast`) and the whole
   drain → append → dispatch chain runs inside one `Turn.settle/2` recursion
   (`Turn.settle/2` → `Executor.run_all/2` → follow event → `settle/2`), with no `receive`
   in any action, so `prepare/1`'s `ctx.inbox_count` and the executor's
   `state.live.inbox` cannot diverge between the decision and the action. Either the cast is
   handled before `:iterate` (the entry is in the batch) or after the drain (`:generating`,
   so it queues for the next boundary). Probe 1 exercised the "before" case through the real
   channel; the "after" case is a plain queue.
3. **A human message during `:stopping`.** Held, and it *is* delivered. `status_for/1` maps
   `:stopping` → `:streaming` (`lib/nest/agents/agent/machine.ex:210`), so
   `busy_status?/1` queues it; `:stop_timer` then emits `{:finalize, …}, {:drain_inbox}`
   (`transitions.ex:151-156`). Probe 2: after `chat:stop`, the transcript is
   `[:system, :user("first turn"), :assistant, :user("[mode: chat]\n[Message from the user
   \"agent-channel-tester\"]\nqueued during stop"), :assistant]` and the inbox is empty — the
   message is delivered as a new turn, not lost. This is the PR body's claim, verified.
4. **A human message during `:compacting` / `:committing`.** Held by reading (no probe: a
   real mid-turn compaction fixture is expensive). `:committing` maps to status
   `:compacting` → queued. Every `Compaction.resume/1` branch drains: `resume_notice` and
   `resume_with_pending` go through `:idle` + `{:drain_inbox}`; the carried
   `{:assistant_response, …}` branch is `:idle` + `{:finalize, :clean}` + `{:drain_inbox}`;
   the `{:compact_tool, …}` resume re-enters `:generating` with the synthetic tool result as
   the tail, so `unpaired_tail_tool_uses/1` is empty and `Boundary.drain?/1` fires; the
   `{:tool_call, …}` resume appends the carried assistant *with its unanswered* `Part.ToolUse`,
   so `unpaired_tail_tool_uses/1` is non-empty and the drain correctly waits for the next
   boundary (this is the load-bearing position the design note claims, and it checks out:
   `Commit.append_entry_tail/2` + `ensure_assistant_tail/2`).
5. **A queued message when the delivered turn needs a compaction, and when it cannot
   compact.** Held. `:needs_compaction` parks the built `%User{}` on
   `pending_user_message` and `resume_with_pending/1` appends it — no duplication (the
   executor consumed the inbox exactly once) and no loss (the message is on the machine).
   `:cannot_compact` restores the drained entries with `{:restore_inbox, entries}`, so a
   second attempt re-drains the same entries rather than a doubled list.
   I looked hard for a *stranded* variant: `Compaction.do_stage/2`'s `{:error,
   :reserve_exhausted}` branch enters `:idle` **without** a `{:drain_inbox}` while
   `pending_user_message` stays set, which would strand the delivered message; it needs
   `system_size + suffix ≥ reserve` at the same moment preflight said `:needs_compaction`,
   i.e. a system prompt that nearly fills the 20 % reserve — and the same hole pre-dates
   this PR on the `:idle` drain (the branch is untouched). Worth an issue, not a PR finding.
   The boundary's `:cannot_compact` path also abandons the in-flight turn without a
   `{:finalize, _}`, so a parent blocked in `agents-query` gets no completion for the turn
   that was running; but `check_messages/3` only returns `:cannot_compact` when the system
   prompt alone exceeds `limit - reserve` (`tokens/pre_flight.ex:112-147`) or the head to
   summarize is empty — and at a boundary the head always contains the turn-opening user
   message — so the reachable window is "the model is fundamentally too small", where the
   agent is already unusable. Not worth a finding.
6. **Two human messages with different modes.** Held as documented (newest wins; § 6 is the
   documentation nit, not a loss/duplication).
7. **A human message queued while the agent is blocked.** Held: `chat_or_queue/4`'s `true ->`
   branch drops it with a log (the channel already answered
   `agent_status_<status>`), and the `Inbox` moduledoc + `needs_repair.ex` say so.
8. **Disposition wrong / lost / duplicated / reordered.** I could not produce any:
   `:idle` → `handle_chat` (unchanged), busy → queue, blocked → logged drop; the drain
   clears the inbox exactly once (the executor's `{:drain_inbox}`), `{:restore_inbox}` is the
   only re-add, and the mode is applied only at drain time (probe 1 asserted
   `state.live.mode != "plan"` while queued and `== "chat"` after the drain — "chat" because
   the probe's agent has the single-mode programmer vocation, so `resolve_mode_and_caps/4`
   correctly fell back to the default; 1.1.10 covers the applied case with a multi-mode
   vocation).
9. **Client-side duplication of the human's message.** Held. The optimistic row is
   retracted on the authoritative `chat:inbox` (`setAgentInbox` →
   `retractQueuedOptimistic`, `assets/js/store/slices/agentInbox.js:33-46`), `buildMerged`
   rebuilds the row from the server's message so the `optimistic` marker cannot survive a
   reconcile (`messageHelpers.js:109-122`), and the real combined row (different text)
   cannot content-match the optimistic row. The one path that could leave a phantom —
   reconnect while queued — is closed by `reconcileAgentCache`'s
   `payload.messageCount < messages.length → resetAgentMessages + full sync`
   (`assets/js/channels/agent.js:130-136`), so the marker-stripping `withoutOptimistic`
   (`assets/js/store/slices/agentCache.js:37-41,113`) is belt-and-braces rather than the
   load-bearing fix (its branch is effectively unreachable, since the reset covers the same
   case — harmless, and defensible as a store-level invariant).

## PR body claims vs. the diff

| claim | verdict |
| --- | --- |
| `iterate/1` in `:generating`/`:chat` is the boundary; `:drain_inbox` stays in `:generating`; decision in `Machine.Boundary`; the `[]` position is load-bearing | accurate (`transitions.ex:501-514`, `machine/boundary.ex`; verified in § 4/§ 5) |
| `ctx.inbox_count` from `length(state.live.inbox)`, one accessor defaulting to 0 | accurate (`turn.ex:206`, `boundary.ex:70-71`) |
| the ~34 hand-built `ctx` tests keep working | accurate (no fixture churn in the diff) |
| stale comments corrected in `Repair`, `MessageAppender`, `MessageList`, `Inbox`, `ChatState`, `tools.ex`, two older notes | accurate (all six code sites + both notes present in the diff; the two notes are marked "superseded by #15") |
| `chat_or_queue/4` is atomic; `:idle` starts now; busy queues; broken drops with a log | accurate (`callbacks.ex:65-88`); the log is asserted by two tests |
| the channel no longer rejects the busy statuses; refuses non-binary `content`/`mode` | accurate (`agent_channel.ex:321-346,603-618`); `@broken_statuses` = `Machine.blocked_phases/0`, and `:compacting` now reaches the agent (its test was updated) |
| the mode is applied at drain time, never at enqueue, resolved through `resolve_mode_and_caps/4` | accurate (`executor.ex:389-405`); verified by probe 1 |
| one mode per combined message: most recent human entry with a mode wins | accurate (`inbox.ex:158-168`); see nit 6 for the undocumented escalation |
| composer stays interactive while busy (Send next to Stop) | accurate (`ChatInput.jsx`, `ChatPage.jsx:471`); the new "model_missing" freeze addition is a *behaviour change* the body does not mention: the composer is now hidden for `model_missing` (previously the textarea was greyed out but visible). Consistent with `frozen`'s new doc, but not called out |
| queued message rendered from `chat:inbox`; `setAgentInbox` retracts the newest matching optimistic row, re-anchors `lastIndex`, clears only that send's placeholder | accurate for the code (`agentInbox.js`, `agentCacheMessages.js:206-243`); the design note says "oldest" (nit 3) |
| the inbox panel labels both sources and shows the requested mode with an explicit missing marker | accurate (`InboxPanel.jsx:24-55`) |
| `:loop_ack` now appends a held `pending_user_message` | accurate (`transitions.ex:93-114`, `held_user/1` at `:632-643`), with the three `unwrap_user/1` shapes + a logged refusal for an unknown shape |
| a queued send while streaming no longer overwrites the live accumulator | accurate (`agentCacheMessages.js:150-160`) |
| `:drain_inbox` publishes a changed mode via `Broadcasts.status/1` | accurate (`executor.ex:316-323`); see observation 10 |
| "every finding they did raise is either fixed in this PR … or tracked below" | the three headline fixes named in the body (malformed-frame crash, lost stream, `:loop_ack` drop) are all in the diff |
| verification numbers (credo 406/4049 clean, 1943 tests 0 failures 3.6 s, coverage 85.1 %, biome clean, no file over the caps, JS 1182/60 0 failures, exit 0) | all accurate — I read the full `precommit-D.log`; the log itself is gitignored (nit 8) |
| "deliberately not taken / known limits": truncation/re-prompt, the compaction *request* turn, `{:preflight_result, :fits}`, the `:invalid`-append loss, #26, #27, the `agents-query` starvation | accurate; #26 and #27 exist and match their descriptions, and I found no issue tracking the starvation bug (the body's "untracked so far" is honest) |
| "the compaction *resume* after a `context-compact` commit *is* one, and that is a behaviour change" | accurate for the `{:compact_tool, …}` carried entry; the `{:tool_call, …}` and `{:user_message, …}` resumes are *not* boundaries (unpaired tool_use / user tail) — the body's phrasing is about `context-compact`, so it holds |
| `pendingMessageCount` from `chat:status` | **not accurate for the broadcast** — see finding 1 |

## Repo and process state

* `git status` clean on `boundary-delivery` at `233c350`, up to date with `origin`; the PR
  is open, non-draft, `MERGEABLE`, no review comments.
* No stray or config-bypassing files: no lint/config changes in the diff, no `package.json`
  or `node_modules` in the project root, `notes/test-runs/` correctly gitignored (and my
  run logs went there).
* Dead/unreachable *in the diff*: finding 1 (`statusExtras`'s `pendingMessageCount`) is the
  only one; `withoutOptimistic`'s branch is effectively unreachable too (defensible, see § 9
  item 9). Out of the diff: `Machine`'s `resume` struct field
  (`lib/nest/agents/agent/machine.ex:159,171`) is never read or written — pre-existing dead
  state, worth deleting when someone is next in that file.
* `notes/`: the three review files are the substantive record; the design note is excellent
  and matches the code except for the two points in nits 3–4; the three task reports are
  unreferenced (nit 7).
