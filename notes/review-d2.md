# Adversarial review — uncommitted `assets/` work, branch `boundary-delivery`

Reviewer: `review-d2`. Scope: `git diff assets/` (10 files) plus the server contract it
depends on (`lib/nest_web/channels/agent_channel.ex`, `lib/nest/agents/agent/{callbacks,inbox}.ex`,
`lib/nest/agents/agent/machine.ex`) read only to check the client's assumptions.
The Elixir half is another reviewer's.

**Tree state during review:** the working tree was left exactly as found (10 modified
`assets/js/**` files + the Elixir half). Nothing was fixed, stashed, reverted or committed.
Only `notes/review-d2.md` and the logs under `notes/test-runs/` were written.

**Verification (all run, full output, no `grep`/`head`/`tail` on test output):**

* `cd assets && pnpm vitest run --no-color` → **60 files, 1176 tests, 0 failures**
  (`notes/test-runs/review-d2-vitest.log`). No console output.
* `cd assets && pnpm vitest run --coverage` → exit 0, thresholds met
  (All files 96.26% stmts / 90.62% branch); `agentInbox.js` 86.2% branch with
  lines 53-54 uncovered (`notes/test-runs/review-d2-coverage.log`).
* `cd assets && pnpm biome check` → clean, 157 files (`review-d2-biome.log`).
* `cd assets && node lint-file-size.mjs` → OK (`review-d2-filesize.log`).
* No `mix` command was run.

Repros below were run with a scratch vitest config under `/tmp/nest-review-d2/` (outside the
repo, so the tree stayed clean) that points `root` at `assets/` and includes only
`/tmp/nest-review-d2/**/*.test.{js,jsx}`. All of them **pass**, i.e. they demonstrate the
behaviour they claim.

---

## B1 — blocker: a queued send while streaming destroys the live `partial`, so the stream vanishes and every later delta is rejected as a gap

`assets/js/store/slices/agentCacheMessages.js:163-176` (the `streaming`/`partial` fields),
reached from `assets/js/pages/ChatPage.jsx:334-350` → `assets/js/channels/agent.js:470-491`
→ `assets/js/store/slices/agentInbox.js:58-69`.

`addUserMessage` unconditionally *overwrites* `cache.streaming` and `cache.partial` with the
fabricated placeholders. Before this change that was harmless because a send while busy was
impossible (`isInputDisabled = status !== "connected" || isAgentBusy`). The change makes
"send while streaming" the feature's headline path, so now:

1. the real in-flight accumulator at index `M` is replaced by `{index: M+1, charsReceived: 0}`;
2. the `chat:inbox` retraction then clears *those* placeholders (`agentInbox.js:58-69`) and
   does **not** restore the real one — nothing saved it;
3. the next `chat:delta` for the still-running stream has `charsStart > 0` against an empty
   partial, so `addChatDelta` returns `{applied: false, needsSync: true}`
   (`store/slices/agentCacheDeltas.js:131-133`), and `channels/agent.js:321-329` logs
   `console.warn("[agent:…] Delta gap at …, expected …. Syncing.")` and pushes `chat:sync`.

`components/StreamingMessage.jsx:26` returns `null` when `partial` is null, so the streaming
assistant text disappears from the UI until the sync reply lands (the sync *does* carry the
partial back, because its index is above the re-anchored `lastIndex`), i.e. a visible glitch
plus a production warning and an extra push on **every** queued send that happens mid-stream.

Repro (`/tmp/nest-review-d2/repro.test.js`, passes):

```js
useStore.getState().setAgentConnected("agent-1", {
  messages: [{ index: 5, role: "user", parts: [{ kind: "text", text: "hi" }] }],
  status: "streaming",
  partial: { index: 6, charsEnd: 3, parts: [{ kind: "text", text: "abc" }], currentKind: "text" },
});
const cache = () => useStore.getState().agentsCache["agent-1"];
useStore.getState().addUserMessage("agent-1", "queue this", "build");
// the real partial at index 6 is gone, replaced by a fabricated one at index 7
expect(cache().partial.index).toBe(7);
expect(cache().partial.charsReceived).toBe(0);
useStore.getState().setAgentInbox("agent-1", [
  { from: "alice", content: "queue this", timestamp: "t1", kind: "user", mode: "build" },
]);
expect(cache().partial).toBeNull();   // nothing restored it
expect(useStore.getState().addChatDelta("agent-1", {
  index: 6, charsStart: 3, charsEnd: 6, content: "def", partType: "text",
})).toEqual({ applied: false, needsSync: true });
```

Minimal fix (not applied): in `addUserMessage`, only fabricate the placeholders when there is
no accumulator in flight, e.g.
`...(cache.streaming || cache.partial ? {} : { streaming: streamingState, partial: partialState })`.
At idle `cache.partial` is always null (the previous turn's `addChatMessage` clears it), so the
normal reconcile path is unaffected; the retraction's `removed.index + 1` check then also has
nothing of the real send to clear. A regression test should assert that a queued send during
`streaming` leaves `partial.index`/`charsReceived` untouched and that the following delta
applies (`needsSync: false`).

## B2 — should-fix: the retraction *can* delete a real row (the "a real message can never be retracted" claim is false)

`assets/js/store/slices/agentInbox.js:32-38`, `assets/js/store/slices/agentCacheMessages.js:114-130`
(doc claim), `assets/js/store/slices/agentCache.js:92-99` (keep-existing-messages) +
`assets/js/channels/agent.js:127` (reconcile no-op on equal `messageCount`).

`optimistic: true` is only cleared by `addChatMessage` (via `buildMerged` spreading the server
message). It is *not* cleared when the client learns the message is real by another route, and
there is one: `setAgentConnected` keeps the cached rows whenever
`existing.messages.length > payload.messages.length` (the `init` payload has no `messages` key),
and `reconcileAgentCache` returns early when `payload.messageCount === messages.length`. An
optimistic echo whose `chat:message` was missed during a socket drop therefore survives a
reconnect *as an optimistic row that stands in for a persisted message* — and a later
same-content queued entry retracts it, deleting the real message from the timeline.

Repro (`/tmp/nest-review-d2/repro5.test.js`, passes): 6 real rows, send "hi" (turn starts, its
`chat:message` is lost to a drop), reconnect with `{messageCount: 7}` (equal to the inflated
cache length → no reset, no sync), then queue "hi" again while busy:

```js
expect(cache.messages.map((m) => m.index)).toEqual([0, 1, 2, 3, 4, 5]); // real row 6 gone
expect(cache.lastIndex).toBe(5);
```

Same root cause, without the reconnect: if two sends share the same text and the first one's
`chat:message` has not been processed yet, the entry pairs with the *first* row. Channel
ordering (the agent publishes `chat:message` for the turn start before it publishes `chat:inbox`
for the later queued send, and the client processes one channel's pushes in order) makes that
hard to hit live, but it is exactly the "oldest still-present optimistic row of the same
content" rule. With the server's mode prefix the content fallback in `addChatMessage` cannot
rescue it, so the result is an out-of-order array and a backwards `lastIndex`
(`/tmp/nest-review-d2/repro4.test.js`):

```js
expect(cache.messages.map((m) => m.index)).toEqual([0, 2, 1]); // unsorted; MessagesList maps in order
expect(cache.lastIndex).toBe(1);                                 // was 2
```

`MessagesList` renders in array order and keys on `message.index`, and `syncAgentMessages` sorts,
so "ascending, unique indices" is a real invariant the store relies on.

Minimal fix directions: clear `optimistic` in `setAgentConnected`/`syncAgentMessages` for rows the
server confirms, and/or match the entry against the *newest* optimistic row (the one whose
fabricated index is the current `lastIndex`), and/or do not lower `lastIndex` below a surviving
optimistic row. At minimum, the doc comment should stop claiming a real row can never be retracted.

## S3 — should-fix: `model_missing` is rejected by the server but not frozen client-side, so a rejected send leaves a permanent phantom bubble

`assets/js/pages/ChatPage.jsx:609-614` (frozen list) vs
`lib/nest_web/channels/agent_channel.ex:36` + `lib/nest/agents/agent/machine.ex:47-53`
(`@blocked = [:needs_repair, :model_missing, :context_overflow, :compaction_failed, :compaction_loop_detected]`).

The client freezes four of the five; `model_missing` is missing, and `setAgentConnected` always
sets `status: "connected"`, so in that state the composer is fully interactive (frozen false,
`disabled` false). The push is rejected `agent_status_model_missing`, `channels/agent.js:488-491`
only calls `clearPartial` + `onError`, and nothing ever retracts the optimistic row: no
`chat:inbox` entry will ever arrive because the message was dropped server-side. The user sees
their text as a sent message plus an error banner, and it will never be delivered.

Repro (`/tmp/nest-review-d2/repro2.test.js`, passes) at the channel level:

```js
setNextPushResult("agent:1:agent-1", "chat:message", { error: { reason: "agent_status_model_missing" } });
sendMessage("agent-1", "hello there", "build", onError);
// after the error:
expect(cache.messages.map((m) => m.content)).toEqual(["hello there"]);
expect(cache.messages[0].optimistic).toBe(true);   // never retracted
expect(cache.inbox).toEqual([]);                   // no entry will ever come
```

This predates the change for `model_missing` (busy was false there anyway), but the same
window is now newly reachable while busy: the client only learns about a transition into a
broken status from a later `chat:status`, so a send in that window is accepted locally and
rejected by the server. Minimal fix: add `agentState === "model_missing"` to `frozen`, and/or
have `sendMessage`'s error path retract the optimistic row it just inserted.

## S4 — should-fix (project rule): new single-assertion tests, and two tests that pass without the feature

`AGENTS.md` — "Tests that have only one assertion in them are extremely suspect as likely
violating the previous rule" (no two tests with compatible setup differing only in one assertion).

* `assets/js/components/ChatInput.test.jsx:472-496` — three consecutive tests with the same
  setup (`{ value: "hello", isBusy: true }`) asserting one thing each: `onSend` on click,
  `onSend` on Ctrl+Enter, and no-send when `disabled`. Merge into one test (submit/click/
  Ctrl+Enter/no-send) or add the assertions to the neighbouring `onSend` tests.
* `assets/js/components/InboxPanel.test.jsx:133-152` and `:154-174` — each has exactly one
  `expect` and identical setup shape (seed a one-entry inbox, render, click, assert the label);
  they differ only in the fixture and the single assertion. Merge into one test with a
  two-entry inbox.
* `assets/js/store/index.test.js:4536` ("does not retract an optimistic row for an agents-send
  entry or a non-matching user entry") and `assets/js/pages/ChatPage.test.jsx:487` ("does not
  send while the agent is busy but the channel is not connected") **pass unchanged with the
  feature removed** — the first is purely negative, the second never attempts an interaction
  (its `expect(sendMessage).not.toHaveBeenCalled()` is vacuous). They are fine as guards but
  they are not feature tests; say so, or make the second actually click Send.

Everything else checks out: all five touched test files grew in test count (168→169, 61→64,
4→8, 72→74, 191→196), every one of the 9 renamed `it(` lines has a replacement (the 10 removed
`expect`s are all inverted/re-pointed, not deleted), no sleeps, no `async: false`, no
`vi.waitFor` misuse in the new tests (the one in `channels.test.js` guards a
`setTimeout(..., 1)` mock delivery), and the suite prints nothing. The mocks assert the public
contract (`sendMessage(name, content, mode, fn)`, rendered labels, store state) rather than
internal call shapes.

## S5 — nit: the slash-command suppression is cosmetic, and the dispatch it hides still runs while busy

`assets/js/components/ChatInput.jsx:289-295` vs `assets/js/pages/ChatPage.jsx:334-350`.

The menu is hidden while busy "because a slash command is a control-plane push that cannot take
effect mid-turn", but `handleSendMessage` parses and dispatches it regardless: type `/compact`
while streaming, submit, and the client pushes `chat:compact`, the agent replies
`{:error, {:not_idle, :streaming}}` (`lib/nest/agents/agent/callbacks.ex:197-205`) →
`agent_status_streaming`, and `setInputValue("")` has already cleared the text. So the user
loses the text and gets an error banner for a command the UI deliberately hid. Either keep the
suggestions visible or skip the slash-command branch while busy (falling through to the normal
queued text, which is what the comment implies).

## Nits

* `assets/js/components/InboxPanel.jsx:31-32` — the "explicit missing sender" marker only exists
  for `kind: "user"`. `{kind: "agent", from: null}` renders **`From agent null`** and an unknown
  kind with no `from` renders `From undefined (unknown kind: ghost)` (repro:
  `/tmp/nest-review-d2/repro3.test.jsx`, passes). `Inbox.label/1` on the server explicitly
  handles a nil agent sender, so nil is a real possibility.
* `assets/js/components/InboxPanel.jsx:106` — the key is defensible (the wire has no id, and
  `DateTime.to_iso8601/1` of a microsecond-precision `DateTime.utc_now()` is unique in
  practice), but two byte-identical entries do collide: React logs
  `Encountered two children with the same key` (verified in the same repro3 file). It also
  embeds the entire `content` in the key string. Consider `timestamp` + `from` only, and have
  the server add an id.
* `assets/js/components/InboxPanel.jsx:78` — `Math.max(count, inbox.length)` can print a count
  larger than the list with no "N of M loaded" indicator; the refetch happens only on expand
  (`handleToggle`) and `requestInbox` has no `receive("error")`, so a failed fetch is silent.
* `assets/js/channels/agent.js:14-53` — `statusExtras` does not forward `pendingMessageCount`,
  so a `chat:status` payload's count is dropped (the field is only read on join/`init`). A
  missed `chat:inbox` broadcast therefore leaves both the count and the list stale until a
  rejoin, which is exactly when the retraction is also missed.
* `assets/js/store/slices/agentInbox.js:26-27` — "Returns `null` … so the caller can keep the
  existing references and skip a re-render" overstates it: `setAgentInbox` always builds a new
  cache object and always writes `inbox`/`pendingMessageCount`. Only `messages`/`lastIndex`/
  `streaming`/`partial` are left alone.
* `assets/js/store/slices/agentInbox.js:52-55` — the surviving-optimistic-row branch is
  uncovered (coverage 86.2% branch) and lowers `lastIndex` below a surviving optimistic row, so
  the next `addUserMessage` reuses its index (`/tmp/nest-review-d2/repro4.test.js`, second test:
  `[0,1]` then `[0,1,1]` → duplicate `key={message.index}` in `MessagesList`).
* `assets/js/components/ChatInput.jsx:229-238` — Stop is not bound to `disabled`, so in the
  not-connected-while-busy state the composer says "can't send" (Send disabled, textarea
  disabled) but still offers a Stop whose only outcome is the "Not connected to agent" error.
  Pre-existing, but the new test at `ChatInput.test.jsx:487` now pins the mixed state.
* `assets/js/components/ChatInput.jsx:66-72` — the `frozen` doc says it is used for `:compacting`
  / `:compaction_failed`; `ChatPage` never freezes `:compacting` (it is a normal busy-queue
  state), and the frozen test names a third set.
* `notes/issue-15-boundary-delivery.md:226-228` — "The composer is disabled while the agent is
  busy … so the queued path has to be reachable from the UI at all" reads as a claim about the
  current code; it is the *old* behaviour (the next clause describes the new one).
* Three-button row (`ChatInput.jsx:340-364`): `flex gap-2` with `px-6` Send *and* Stop squeezes
  the textarea on narrow viewports (the textarea has no `min-w-0`). Cosmetic; worth a look.
* `setAgentInbox`'s retraction leaves `waitingForResponse: true` from `addUserMessage` for a
  send that did not start a turn. Harmless today (`chat:status: idle` clears it, and
  `streaming`/`executingTools` win the typing indicator) but it is a stale flag.

---

## What I tried to break, and why it held

* **Content matching / trimming.** The server stores the entry verbatim and `ChatPage` sends the
  trimmed input, which `sendMessage` writes into the optimistic row, so equality is exact.
  Confirmed against `Inbox.label/1`/`combine/1` (no `[mode: …]` prefix on the stored content) and
  against the fact that a mode prefix on the *entry* would have broken the match — the author's
  note says so too. Held.
* **Two optimistic rows + two identical entries.** Each entry consumes at most one row
  (`removed` set), the list is a cumulative snapshot replaced wholesale, and entries arrive in
  send order, so N identical sends produce N entries and retract N rows. Held (pinned by the
  author's "oldest first" test).
* **Can it retract a *different* send's optimistic row?** Only for identical content, where the
  rows are indistinguishable, and then each row is removed at most once — the count matches the
  number of queued sends. Held, except for the real-row cases in B2.
* **A missed `chat:inbox` broadcast.** The optimistic row survives and the delivered real
  message reconciles it by index (the content fallback cannot match because of the mode prefix),
  so no duplicate bubble. Held — but the count/list stay stale (see the `statusExtras` nit).
* **`lastIndex` never pointing at a removed row.** It is recomputed from surviving non-optimistic
  rows, so it always points at a real row or `-1`. Held. It *can* go backwards relative to
  surviving optimistic rows (B2).
* **Fabricated `streaming`/`partial` cleanup when a real assistant row already replaced them.**
  The `removed.index + 1` guard leaves a foreign placeholder alone, and the author's test pins
  it. Held.
* **`kind: "agent"` / unknown `kind` retracting nothing.** `entry?.kind !== "user"` is checked
  first. Held.
* **Stop while busy.** Still rendered and wired; `stopping` only disables Stop. Held (except the
  not-connected nit).
* **The panel's wording/keys/transparency.** Wording is accurate for both kinds; unknown kinds
  and missing modes show explicit markers; `From you` is keyed to the signed-in username, and
  the "no current user" case is tested. Held except the non-`user` missing-sender nit.
* **Project rules.** Modern hooks, the single zustand store, Tailwind list syntax/`@apply` (no
  `@apply` anywhere in the diff), no lint-config bypass, no `biome-ignore` added, file/function
  lengths fine (`agentInbox.js` 96 lines, `retractQueuedOptimistic` ~44), `biome check` and
  `lint-file-size.mjs` clean. Held.
