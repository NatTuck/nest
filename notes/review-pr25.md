# Review — PR #25 (`async-messages`, issue #17) on the merged tree (`316b339`)

Scope: #17 (`agents-wait` + async modes) **after** merging `main` (`be37644`, #15).
Nothing outside this file was modified. No `git stash`, no revert, no commit, no branch switch.

Runs performed (full output on disk, no filtering):

| run | result | log |
| --- | --- | --- |
| `mix test` on the #17 files (`wait_loop_test`, `tool_loop_async_test`, `sub_agent_tools_test`, `tools_test`, `groups_test`) | 68 tests, 0 failures, 0.7 s | `notes/test-runs/pr25-targeted.log` |
| `mix test` on #15's integration files (`machine_boundary_delivery_test`, `turn_acceptance_test`, `agent_channel_queued_message_test`, `inbox_test`) | 36 tests, 0 failures, 1.1 s | `notes/test-runs/pr25-merge-15tests.log` |
| `cd assets && pnpm vitest run components/DelegatedTaskBlock.test.jsx` | 21 tests, 0 failures | `notes/test-runs/pr25-js-delegated.log` |

I did not run `mix precommit` or the full suite (per instruction), and I did not run credo/biome.

---

## 1. Merge soundness

**Verdict: the merge is a clean union, and I found no #17 text that asserts #15's old
"drop while busy" / "drain at idle only" behaviour.**

Evidence:

* `git diff main...async-messages` is exactly the #17 diff (`28 files, 2282 insertions(+),
  421 deletions(-)`), byte-for-byte the same stat as `git diff b726045 02b3407`.
* The five files both sides touched — `agent/broadcasts.ex`, `agent/callbacks.ex`,
  `agent/chat_state.ex`, `messages/message_list.ex`, `lib/nest/tools.ex` — each contain
  **both** changes; I read all five merged versions.
  * `tools.ex:298-320`: #15's corrected LLM-facing `agents-send` description ("delivered
    together with any other queued messages **at its next turn boundary — before it starts
    its next request, or when it goes idle if the turn ends first**") survived the merge.
  * `broadcasts.ex:31-38`: #17's public `topic/2` (used by `PeerQuery` + `WaitLoop`) and
    #15's `pendingMessageCount` in `status_payload/1` coexist.
  * `message_list.ex:380-395`: #17's `last_assistant_text/1` plus #15's comment fixes.
* I grepped every file #17 touched for `drop` / `goes idle` / `drain` / `busy`: nothing
  asserts the pre-#15 disposition. `ToolLoop`'s `agents-send` comment ("the target either
  starts one (idle) or queues the message (busy)") is #15-correct.
* #15's tests still pass on the merged tree (table above), and so do #17's.

**Stale references after the merge** (nit severity, but they are the "now false" claims):

* `notes/issue-15-17-async-messages.md:4` — "Branch `async-messages`, off `main`
  (`b726045`)". `main` is `be37644` and the branch now contains #15.
* `notes/issue-15-17-async-messages.md:24-30` — "This branch is #17 only: A + B." and
  "**C lives on its own branch** (`boundary-delivery`)". C is now merged here, and the
  sentence "at the parent's next turn boundary once #15 lands, and at its turn end before
  that" (`:36-38`) describes a past state.
* `notes/issue-15-boundary-delivery.md:163`, `:335` — "`ToolLoop.wait_for_idle/5`". That
  function no longer exists; #17 moved it to `Nest.Agents.Agent.PeerQuery.wait_for_idle/6`
  (`lib/nest/agents/agent/peer_query.ex:91`).
* `notes/issue-15-boundary-delivery.md:338` — "(`agents-wait`, the blocking peer wait,
  arrives with #17 on its own branch and has the same property.)" — it is now in this tree.
* `notes/issue-15-boundary-delivery.md:359` — `tools.ex:437-449` is stale (#17 deleted that
  region; the `agents-send` description now lives at `tools.ex:298-320`).

---

## 2. BLOCKER

### B1. The new child-name link points at a route that does not exist — the PR body's drill-down claim is false

`assets/js/components/DelegatedTaskBlock.jsx:312`

```jsx
to={`/agent/${encodeURIComponent(childName)}`}
```

The router has no such route. `assets/js/App.jsx:159-170` defines only
`/login`, `/register`, `/`, `spaces`, `spaces/new`, `space/:spaceSlug`,
`space/:spaceSlug/agent/:name`, `about`, `invites`, `providers` — there is no catch-all, so
React Router renders **nothing** (not even `Layout`) for `/agent/worker-1`: the user gets a
blank page. Every other agent link in the app is space-scoped:
`SidebarSpaceRow.jsx:131,180,322`, `ChatHeader.jsx:90`, `SpaceView.jsx:75` all build
`/space/${spaceSlug}/agent/${encodeURIComponent(name)}`.

The link itself is old code (`git show b726045:...jsx` has the same `to=`), but before this
PR `childName` was never passed, so the branch was unreachable. #17 makes it reachable and
the PR body advertises it as the *only* way to read an async answer:

> "It also now links the child's name (documented but never passed before), which is how a
> user drills into the child's own chat to read an async answer."

That claim is false of the current tree. The async answer is delivered as an inbox message
(`AsyncWaiter` → `Agent.deliver_message/3`), so there is no other affordance to reach the
child's transcript.

Reproduction: run `pnpm vitest run components/DelegatedTaskBlock.test.jsx`, then visit
`/agent/<child>` in the running app (or add a `<Route>`-less `MemoryRouter` render and
assert `container.firstChild === null`). The new test at
`assets/js/components/DelegatedTaskBlock.test.jsx:179` asserts `href == "/agent/worker-1"`,
so the suite currently **pins the broken URL** and cannot catch this.

Minimal fix (choose one):

* read the slug from the route inside the component —
  `const { spaceSlug } = useParams();` then
  `to={`/space/${encodeURIComponent(spaceSlug)}/agent/${encodeURIComponent(childName)}`}`
  (the component only ever renders under the `ChatPage` route); or
* thread `spaceSlug` `ChatPage.jsx:484` → `MessagesList` → `Message.jsx:153` →
  `DelegatedTask` → `DelegatedTaskBlock`.

Either way the test must render inside a route (`MemoryRouter` +
`<Routes><Route path="/space/:spaceSlug/agent/:name" element={...}/></Routes>`) and assert
the space-scoped href, so the regression is impossible to reintroduce.

---

## 3. SHOULD-FIX

### S1. `agents-query` (both modes) can resolve with the peer's *own previous turn* — **already tracked as #30**, but two items are in scope here

`lib/nest/agents/agent/peer_query.ex:10-13`, `lib/nest/agents/agent/peer_query.ex:91-120`,
`lib/nest/tools/query_agent.ex:27-34`.

**Status: known.** `notes/issue-30-design.md` (untracked WIP, 438 lines) documents this
exact mechanism, including the turn-end transient idle ("So the peer is broadcast `idle`,
then `streaming` … The waiter accepts the **first** idle"), and #15's PR body tracks it as
#30. I re-derived it independently from the code and reach the same conclusion; I am
reporting it only because the review asked me to attack false wait resolution, and because
two *small* items are in scope for **this** PR rather than for the #30 fix:

* the moduledoc sentence below is misleading in the tree as it stands, and
* there is no test that pins the busy-peer behaviour the fix will have to preserve.

The moduledoc claims:

> "We capture the target's message count BEFORE sending so the first idle we see is only
> accepted once a NEW assistant message (index >= pre_count) exists — this guards against
> reading a stale, pre-query response."

That guard does not work for a **busy** peer, which is exactly the case #15 changed (a
`chat` to a busy peer is now queued instead of dropped, `callbacks.ex:75-91` +
`inbox.ex:104-141`). The mechanism:

1. B is streaming its final response of a turn (`:generating`/`:chat`, status `streaming`).
2. C calls `agents-query B` (blocking or `async: true`). `PeerQuery` subscribes, captures
   `pre_count = N`, casts `chat`, which queues on B (`Inbox.handle_delivery/3`, busy branch).
3. B's response lands. `machine/response.ex:143-159` enters `:idle` and appends the
   assistant message, then runs `[{:finalize, :clean}, {:drain_inbox}]`.
4. `turn/executor.ex:306-326` runs `{:drain_inbox}` **without changing the phase**, and
   `turn.ex:55-68` broadcasts the status *before* recursing on the follow event
   `{:inbox_drain, entries, content}`. So the observable sequence is
   `streaming → idle → streaming` — a transient idle is published while a message is queued
   and about to start a turn.
5. `PeerQuery.wait_for_idle/6` (`peer_query.ex:99`) sees `{:chat_status, %{status: "idle"}}`
   and calls `read_last_assistant_after/3`, which accepts the assistant message just
   appended (its index is `>= pre_count`) and returns **B's answer to its own previous
   turn** as "the response" to C's query. B then answers C's query in the new turn, but
   nobody reads that.

Before #15 this was still wrong but less harmful (the message was dropped, so the answer was
never going to exist). After #15 the peer *does* answer, and the caller still gets the wrong
text. With `async: true` the wrong text arrives later as `[agents-query result]`, out of
context, with nothing to tell the caller which turn it came from.

This is tracked as issue #30 in #15's PR body and in `notes/issue-30-design.md`, so it is
**not a blocker for #25**. Note that `notes/issue-15-boundary-delivery.md:334-339` asserts
the opposite ("It is not resolved *falsely* by this design (no transient idle is
broadcast)") — that reasoning holds for the *boundary* drain (`transitions.ex:509`, which
stays `:generating`) but not for the **turn-end** drain, which is the case above; the #30
note corrects this, the #15 note was not updated.

Note the two tools disagree: `agents-wait` is *not* affected, because `WaitLoop` re-reads
the target's status with `Nest.Agents.get_info/2` (a `GenServer.call` to the target,
`wait_loop.ex:162-175`), which is serialized after the whole settle and therefore observes
the final `:generating` phase. `PeerQuery` trusts the broadcast. (See §5 — that immunity is
real but fragile, and it is currently undocumented in `WaitLoop`.)

Actionable for #25 (both cheap):

1. State the limitation where a tool user sees it: `PeerQuery`'s moduledoc (the pre-count
   sentence is currently misleading) and `Nest.Tools.QueryAgent`'s description ("wait for
   its response" is not what happens for a busy peer). This is the "tool-facing text is
   accurate now that a busy peer queues rather than drops" requirement.
2. Pin the behaviour with a test (a query to a busy peer) so the #30 fix has a baseline —
   there is currently no coverage of this path in either mode (see S2).
3. The real fix (correlation via a per-call id — the plan in `notes/issue-30-design.md`) is
   #30-sized and correctly out of scope for #25.

### S2. No test for an async spawn whose child is stopped (the documented limitation)

`test/nest/agents/agent/tool_loop_async_test.exs` is otherwise good, but:

* **No test for an async spawn whose child is stopped** — the documented limitation. The
  timeout path is covered only by hand-feeding the waiter
  (`tool_loop_async_test.exs:161-166`: `run_spawn_waiter(parent, name, [{:spawn_agent_go,
  "child-slow"}], 20)`), which does not exercise `{:stop_all_children}` →
  `Children.step({:abandoned, name})` (`children.ex:100-102`, which clears `worker_ref` and
  emits only `{:stop_child, name}`) → waiter gets no message → `[agents-spawn timed out]`.
  That is the path the PR body's "Known limitation" paragraph describes, and it is the one
  a user will actually hit after pressing Stop.
* Nothing asserts that a stopped/abandoned child's waiter delivers **exactly one** message
  (the duplicate-delivery risk for that path).
* (A busy-peer query test is also missing, but the #30 note already plans the tests that
  will pin that path, so it belongs to that change, not to #25.)

### S3. The Stop limitation is stated only in the PR body/design note, and it is not the only limitation

The PR body and `notes/issue-15-17-async-messages.md:111-124` are honest about
"a Stop does not cancel a waiter", but a *user of the tool* never sees it:
`lib/nest/tools/spawn_agent.ex:46-49,90-93` promises the response "arrives later as a
message", and the UI card says "The response will arrive later as a message."
(`DelegatedTaskBlock.jsx:341-346`). After a Stop the user gets a spontaneous
`[agents-spawn timed out]` / "Child agent did not complete in time." message instead. One
clause in the tool description (and in the card's async note) would close that gap.

Two more undocumented limits of the same kind:

* **A refused delivery loses the result.** `async_waiter.ex:21-23,176-186`: if the calling
  agent is in a broken status (`:needs_repair`, `:context_overflow`, `:compaction_failed`,
  `:model_missing`) or its inbox is full, `Agent.deliver_message/3` returns an error, the
  waiter logs a warning and exits, and the result is gone — invisible to the model *and* to
  the user. That is at odds with the project's UI-transparency rule ("if it gets sent to the
  LLM or the LLM sends it back then it's visible in the UI"): here the tool said "the
  response will arrive later" and then nothing arrives, with no UI trace.
  `tool_loop_async_test.exs:246-266` pins the log line, so the *logging* is intentional; the
  gap is that the user-facing promise is unconditional.
* **A caller whose machine is rebuilt loses the child entry.** `Children.step/2` ignores an
  event for an unknown child (`children.ex:126-128`), so a caller that went through
  recovery/repair (or whose machine was recreated) gets a false
  `[agents-spawn timed out]`/"did not complete in time" for a child that did complete.

---

## 4. NITs

* **N1** `lib/nest/agents/agent/wait_loop.ex:13-15` — "A name that resolves to no agent at
  all (no live process **and** no persisted row) is an error". `status/2`
  (`wait_loop.ex:172-175`) maps *any* `get_info` error to `:not_found`, and
  `Nest.Agents.get_info/2` (`lib/nest/agents.ex:92-104`) **on-demand-loads** a persisted-only
  agent. So the named path *starts* an agent as a side effect of a read-only wait (then
  reports "Agent X is idle, but its turn produced no text message"), while the `[]` path
  (`wait_loop.ex:70-80`) treats the same agent as already idle without starting it. Two
  dispositions for the same agent, depending on how it is named.
* **N2** `lib/nest/agents/agent/wait_loop.ex:190-198` — `{"names": "bob"}` (a string, not a
  list) is silently filtered to `[]`, which means **"every other agent in the space"**. A
  model that passes a bare string therefore gets a wait on (and possibly the stop message
  of) an unrelated agent instead of an error. The schema declares `array`; the project's
  stance elsewhere is "fail loudly rather than silently drop" (`callbacks.ex:60-66`). Same
  shape for `{"timeout": -1}` (`extract_timeout/1` accepts any integer, yielding
  "No agent went idle within -1ms").
* **N3** `test/nest/agents/agent/wait_loop_test.exs:105-115` — "an empty list with no other
  agents returns immediately" is a single-assertion test whose setup is compatible with the
  `run(%{})` case of the previous test (stub the listing, call `run(%{})`). AGENTS.md says to
  merge those. Also `stub_statuses/1` uses `Agent.start_link/1` where AGENTS.md asks for
  `start_supervised!/1` (it is linked to the test process, so cleanup does happen).
* **N4** `lib/nest/agents/agent/async_waiter.ex:59,73` — `@spec ... ::
  DynamicSupervisor.on_start_child()` is a loose type for `Task.Supervisor.start_child/3`
  (`{:ok, pid} | {:error, term}`).
* **N5** Duplicated constants with "mirrors the other" comments: `@default_wait_ms 300_000`
  in `tool_loop.ex:47` and `wait_loop.ex:49`; `@wait_slice_ms 250` in `peer_query.ex:33` and
  `wait_loop.ex:50`. One definition would remove the drift risk.
* **N6** `lib/nest/agents/agent/wait_loop.ex:145` — the `_other -> await_idle(...)` catch-all
  silently discards *every* non-status message, including a late
  `{:spawn_agent_result, …}` from a sibling blocking `agents-spawn` in the same batch that
  timed out first. Low impact (the batch is sequential in one worker) but worth a comment.
* **N7** `assets/js/components/DelegatedTaskBlock.jsx:341-346` — the async card's state is
  static: after the result message arrives the card still reads "The response will arrive
  later as a message." (there is no `tool_call_id` on the delivered inbox message to
  correlate with). Acceptable for v1; noting it because the review asked about the card's
  async state.
* **N8** `lib/nest/agents/agent/wait_loop.ex:104-108,136-147` — the safety property that
  makes `agents-wait` immune to #30 (a status broadcast is treated only as a *hint*; the
  `Nest.Agents.get_info/2` re-read is the authority, and that call is serialized behind the
  whole settle) is undocumented. The comment at `:106` explains only the missed-broadcast
  case. Anyone "optimizing" `await_idle/4` to trust the broadcast payload — the way
  `PeerQuery` does — would immediately inherit #30 in `agents-wait` too. One sentence
  ("never decide on the broadcast alone: #15's turn-end drain publishes a transient idle")
  would pin it.
* **N9** `notes/issue-15-17-async-messages.md` / `notes/issue-15-boundary-delivery.md` stale
  references — see §1.

---

## 5. What I tried to break, and why it held

| attack | result |
| --- | --- |
| **`agents-wait` resolving falsely on the transient idle** (#15's turn-end drain publishes `streaming → idle → streaming`, `turn.ex:55-68`) | **Held.** `WaitLoop.check_idle/4` → `idle_target/2` → `Nest.Agents.get_info/2` is a `GenServer.call` to the target, queued behind the in-flight settle (including the follow-event recursion, which is a plain call in the same callback), so it always observes the *final* phase (`:generating`) and keeps waiting. The `agents-query` path does **not** have this protection — see S1. |
| **A wait returning the wrong agent's name/message** | Held. `check_idle/4` returns `{name, idle_message(name, stop_message(space_id, name))}` from the same name; the target list is deduped and the caller is removed (`wait_loop.ex:83-89`). |
| **An async spawn result being lost because it beat the go signal** | Held (`async_waiter.ex:63-74`): `spawn_wait/4` accepts `{:spawn_agent_result, …}`/`{:spawn_agent_error, …}` before `{:spawn_agent_go, _}` and still delivers, using the name from the message. `tool_loop_async_test.exs:143-150` pins it. |
| **Duplicate delivery of an async spawn result** | Held. `Children.terminal/6` is first-transition-wins (`children.ex:110-141`), and the waiter delivers once and exits; `await_delivery/2` asserts *exactly one* matching message. |
| **A waiter outliving its caller / doing DB work after a test** | Held. One deadline bounds both phases (`remaining/1` clamped at 0), the caller is monitored (`async_waiter.ex:62`), and the caller's death path exits `:normal` (no crash report). Every new test asserts the waiter's `:normal` `:DOWN` or that `find_waiter_task/0` is empty. |
| **The blocking paths drifting from the async bodies** | Held. `SubAgentResults` is byte-for-byte the old `bound_content/3` + the old per-reason strings; the spawn empty-response and timeout cases keep `is_error: true` on the blocking side and the same *text* on the async side. |
| **The merge silently dropping #15's work** | Held. Diff-stat equality with the #17 patch plus a read of all five overlapping files (see §1). |
| **#17 tests being timing-dependent** | Held. The idle broadcast is pre-seeded with `send(self(), …)` or the timeout is `< 1` slice, so no test sleeps; fences are `500`/`20`/`1` ms; `Mimic` is in private mode (`Mimic.allow(Nest.Agents, self(), coordinator_pid)`), so the async tests do not clobber each other's stubs. |

## 6. PR body (`gh api … /pulls/25 --jq .body`)

Claims that need changing:

* **"It also now links the child's name …, which is how a user drills into the child's own
  chat to read an async answer."** — false of the current tree (B1). Either fix the route or
  drop the claim.
* **Verification numbers** ("1938 Elixir tests … 85.0% … 1167 JS tests") are for the
  pre-merge branch head; they must be re-taken after merging #15 (the user is doing this).
* **"the `agents-spawn`/`agents-query` tool specs move out of `Nest.Tools` …, following the
  existing `WaitAgents`/`FileTools`/`ShellJobs` pattern"** — `WaitAgents` is added by *this*
  PR (commit `8bb1ef9`), not pre-existing.
* **The Known-limitation section** should mention (or the tool text should) the two extra
  limits in S3 (refused delivery loses the result; a rebuilt machine loses the child entry),
  and the body should note the #15 merge and its effect on `agents-query` (S1 / issue #30).

Everything else in the body I checked against the tree and found accurate, including the
`SubAgentResults` single-builder claim, the waiter-starts-first ordering, the
monitor-the-caller behaviour, and "the blocking paths are behaviour-preserving".
