# Task D2 report — browser-side half of issue #15 (queued human messages)

Branch `boundary-delivery`. Scope: `assets/**` only (plus `notes/test-runs/` for logs).
No `mix` command, no Elixir tests, no dev server, no `git stash`/branch switch/commit.

## 1. Files changed

| File | Change |
| --- | --- |
| `assets/js/components/ChatInput.jsx` | While `isBusy`, the textarea + mode selector stay enabled and Send is rendered **alongside** Stop (split `renderActionButton` into `renderSendButton`/`renderStopButton`); only `disabled` gates the keyboard, the form submit, and the two inputs; doc comment updated (incl. the deliberately-suppressed slash menu). |
| `assets/js/pages/ChatPage.jsx` | `handleSendMessage` no longer early-returns on `isAgentBusy`; `isInputDisabled` is now just `status !== "connected"`; both comments corrected. Slash commands and the `frozen` list untouched. |
| `assets/js/store/slices/agentCacheMessages.js` | `addUserMessage` tags its fabricated user row with `optimistic: true` (index/placeholders unchanged); documented why. |
| `assets/js/store/slices/agentInbox.js` | `setAgentInbox` now runs `retractQueuedOptimistic/2`: pairs each `kind: "user"` entry with the oldest still-present `optimistic` row of the same `content` (each entry at most once, in list order), removes it, re-anchors `lastIndex` on the newest surviving non-optimistic row, and clears `streaming`/`partial` only when they sit at `removed.index + 1`. Returns `null` (no state change) when nothing matched. |
| `assets/js/components/InboxPanel.jsx` | Count wording → "N message(s) waiting to be delivered"; `From agent <from>` / `From you` labels; per-user-entry mode badge with an explicit `Mode: (missing)` marker; unknown `kind` called out instead of mislabelled; key widened to the whole entry. |
| `assets/js/components/ChatInput.test.jsx` | 3 corrected tests + 3 new. |
| `assets/js/pages/ChatPage.test.jsx` | 3 corrected/strengthened tests + 2 new. |
| `assets/js/store/index.test.js` | `optimistic: true` pinned on `addUserMessage`; 5 new `setAgentInbox` retraction tests. |
| `assets/js/components/InboxPanel.test.jsx` | 2 corrected + 2 new (both kinds, missing mode, unknown kind). |
| `assets/js/channels.test.js` | 1 new end-to-end test: `sendMessage` then a `chat:inbox` with a `kind: "user"` entry retracts the optimistic row. |

## 2. Commands run and results (verbatim)

All run from `assets/`, full output read (never piped through grep/head/tail), logs under `notes/test-runs/`.

### `pnpm vitest run --no-color` — PASS (exit 0)

Log: `notes/test-runs/task-d2.log` (full file, 69 lines). Verbatim tail:

```
 Test Files  60 passed (60)
      Tests  1174 passed (1174)
   Start at  10:10:55
   Duration  11.03s (transform 8.03s, setup 3.92s, import 20.84s, tests 21.11s, environment 42.37s)
```

Per-file lines for the touched files, verbatim:

```
 ✓ js/components/InboxPanel.test.jsx (6 tests) 208ms
 ✓ js/components/ChatInput.test.jsx (64 tests) 906ms
 ✓ js/store/index.test.js (196 tests) 87ms
 ✓ js/pages/ChatPage.test.jsx (74 tests) 750ms
 ✓ js/channels.test.js (169 tests) 9452ms
```

No failures, no skipped tests, no console noise / React key warnings in the output.

### `pnpm biome check` — PASS (exit 0)

Log: `notes/test-runs/task-d2-biome.log`. Verbatim:

```
Checked 157 files in 72ms. No fixes applied.
```

(An earlier run failed on `lint/suspicious/noArrayIndexKey` for my first `InboxPanel` key; I fixed the code rather than the lint config — see §4.2.)

### `node lint-file-size.mjs` — PASS (exit 0)

Verbatim:

```
OK: no source file exceeds 500 code lines or 700 total lines.
```

## 3. Tests changed, and exactly why

Corrected from the old "disabled while busy" intent to the new intent:

- `ChatInput.test.jsx` "renders a Stop button when the agent is busy" → now asserts Stop appears **alongside** an enabled Send (was `expect(sendButton).toBeNull()`).
- `ChatInput.test.jsx` "renders a disabled 'Stopping…' button when isBusy && stopping" → same, plus Send present.
- `ChatInput.test.jsx` "disables the textarea when isBusy is true (no typing while busy)" → now asserts the textarea is **not** disabled; renamed to say messages are queued.
- `ChatInput.test.jsx` "does not call onSend on form submit when isBusy is true" → now asserts `onSend` **is** called.
- `ChatInput.test.jsx` "does not call onSend on Ctrl+Enter when isBusy is true" → now asserts it sends.
- `ChatInput.test.jsx` "does not cycle on Ctrl+M when isBusy" → now asserts it cycles (see §4.3).
- `ChatInput.test.jsx` history-nav "is a no-op when isBusy is true" → now asserts history navigation works while busy (see §4.3).
- `ChatPage.test.jsx` "disables the mode dropdown when the agent is busy (locked with the input)" → now asserts textarea + dropdown stay enabled.
- `ChatPage.test.jsx` "shows the Stop button when the agent is streaming" / "…executing tools" → strengthened to also assert Send is present (they were single-assertion tests, which the testing rules flag as suspect).
- `InboxPanel.test.jsx` count/`From …` assertions → new wording ("waiting to be delivered") and per-kind labels.

New tests added:

- `ChatInput.test.jsx`: Send-button click while busy calls `onSend`; Ctrl+Enter while busy **and** `disabled` does not send; slash-command menu suppressed while busy.
- `ChatPage.test.jsx`: sends while `agentState === "streaming"` and calls `sendMessage` with the picked mode; busy-but-not-connected still disables the composer and does not send.
- `store/index.test.js`: `optimistic: true` pinned on the fabricated row; retraction happy path (row removed, `lastIndex` restored, placeholders cleared, inbox stored); `kind: "agent"` entry and non-matching `user` entry retract nothing; each entry consumes at most one row (two identical rows + two identical entries); foreign `streaming`/`partial` left alone; `lastIndex` left unchanged when every survivor is optimistic.
- `InboxPanel.test.jsx`: renders an `agents-send` entry and a queued human entry side by side (with `Mode: build`); explicit `Mode: (missing)` marker; unknown `kind` is called out.
- `channels.test.js`: `sendMessage` (optimistic row) followed by a `chat:inbox` carrying a `kind: "user"` entry retracts the row, clears `streaming`/`partial`, and stores the inbox.

No test or assertion was deleted. Every test file I touched grew:
`ChatInput.test.jsx` 61→64, `ChatPage.test.jsx` 72→74, `store/index.test.js` 191→196,
`InboxPanel.test.jsx` 4→6, `channels.test.js` 168→169 (+13 total).

## 4. Unverified / where the spec looks wrong

1. **`lastIndex` fallback is self-contradictory.** The spec says "restore `lastIndex` to the highest `index` among the remaining rows that are not marked `optimistic` (or leave it unchanged if no such row exists — **never** leave `lastIndex` pointing at a removed row)". When the retracted row was the only row, "leave unchanged" *does* leave `lastIndex` at the removed row's index. I implemented the literal rule (leave unchanged) and pinned it with a test; it is harmless in practice (`addChatMessage` finds no match and re-stamps `lastIndex`). If the intent was "reset to `-1` when nothing survives", that is a one-line change.
2. **The React key cannot be made truly unique.** `chat:inbox` entries carry no id, and biome's `noArrayIndexKey` (which I must not bypass) forbids the index. I keyed on the whole tuple `kind-from-timestamp-content-mode`, which is strictly more unique than the previous `from-timestamp-content`, but two byte-identical entries in one list would still collide (React would warn). Flagging rather than silently ignoring "keep the key unique and stable".
3. **I made the whole composer interactive while busy, not just Ctrl/Cmd+Enter.** Removing the blanket `if (disabled || isBusy) return;` from `handleKeyDown` also enables Ctrl+M mode cycling and Ctrl+Up/Down history recall while busy — consistent with "the mode selector stays enabled", but beyond the literal wording of item 1. If those two should stay no-ops while busy, say so and I will restore a narrower guard (the two tests go back to asserting the no-op).
4. **Stop's `disabled` is unchanged** (it is not bound to the `disabled` prop). "`disabled` must still disable everything" is honored for the textarea, mode selector and Send; in the transient *not-connected-while-busy* state the Stop button is still clickable, exactly as before this change. I chose not to alter pre-existing behaviour you did not ask about.
5. **Slash-command suggestions stay suppressed while busy** (the spec's explicit option); documented in both the module doc and inline, and pinned by a test.
6. **Test-count discrepancy:** the brief said 1167 existing tests; the run reports 1174 total and my per-file deltas are +13, implying a 1161 pre-change baseline. I did not run the pre-change suite (nor `git stash`) to confirm. Every pre-existing test file I touched grew, so nothing was dropped.
7. **Not verified:** the server half (queue-on-inbox, combined labelled delivery text) is the other agent's work. I verified only the client contract against the documented wire shape (`kind`/`mode`/`from`/`content`/`timestamp`) via mocks; I could not observe a real end-to-end queue → deliver cycle.

## 5. Follow-up 1 (detail): lastIndex fallback

Per review, §4.1 was resolved by fixing the code rather than the report: `lastIndex` is
always derived from real message rows elsewhere in the store (`setAgentConnected` and
`syncAgentMessages` both compute it from `finalMessages`), so when no real row survives a
retraction it must be `-1`, not left pointing at the retracted row.

Diff summary (2 files, 2 hunks):

- `assets/js/store/slices/agentInbox.js` — in `retractQueuedOptimistic/2`:
  `const lastIndex = restored === null ? cache.lastIndex : restored;`
  → `const lastIndex = restored === null ? -1 : restored;`
  Comment rewritten to say why: the fabricated index must not be reused as the anchor for
  the next optimistic send, and `addChatMessage`'s gap check treats `-1` as "no known rows".
- `assets/js/store/index.test.js` — the pinned test is now
  "resets lastIndex to -1 when every surviving row is optimistic" (was "leaves lastIndex
  unchanged when every surviving row is optimistic"), asserting `cache.lastIndex === -1`,
  with an intent comment giving the same rationale.

No other file changed. The other four retraction tests are unaffected (they keep a real
assistant row at index 0, so `lastIndex` is still `0`).

### Commands re-run (verbatim)

`cd assets && pnpm vitest run --no-color` — PASS (exit 0). Log: `notes/test-runs/task-d2.log`.

```
 Test Files  60 passed (60)
      Tests  1174 passed (1174)
   Start at  10:14:44
   Duration  11.22s (transform 8.76s, setup 3.36s, import 21.13s, tests 20.57s, environment 43.22s)
```

Touched files, verbatim from the same log:

```
 ✓ js/store/index.test.js (196 tests) 88ms
 ✓ js/components/InboxPanel.test.jsx (6 tests) 265ms
 ✓ js/components/ChatInput.test.jsx (64 tests) 859ms
 ✓ js/pages/ChatPage.test.jsx (74 tests) 843ms
 ✓ js/channels.test.js (169 tests) 9443ms
```

`cd assets && pnpm biome check` — PASS (exit 0):

```
Checked 157 files in 74ms. No fixes applied.
```

`cd assets && node lint-file-size.mjs` — PASS (exit 0):

```
OK: no source file exceeds 500 code lines or 700 total lines.
```

### Agreement with the D1 server context

No disagreement. D1 puts the human's content in the inbox entry **verbatim** (no mode
prefix) with `kind: "user"` and the requested `mode`, under the unchanged
`{"messages": [...]}` shape — which is exactly what the client assumes:

- `retractQueuedOptimistic/2` matches an entry to an optimistic row by exact `content`
  equality. `ChatPage.handleSendMessage` trims the input and pushes that trimmed string as
  `content`; `sendMessage` writes the same string into the optimistic row. A verbatim
  server echo therefore matches, and a mode prefix on the entry would have broken the
  match (so verbatim is the required behaviour, not just the observed one).
- Only `kind === "user"` retracts; `kind: "agent"` (and a missing/unknown `kind`) never
  does.
- `InboxPanel` renders `From you` + the requested `mode` for `kind: "user"`, and
  `From agent <from>` for `kind: "agent"`, with an explicit `Mode: (missing)` marker if a
  user entry's `mode` is absent.

## 6. Follow-up 2 (detail): user-entry sender attribution

The panel can be open on an agent other humans are talking to, so `From you` for every
`kind: "user"` entry was wrong. `senderLabel` now takes the signed-in username
(`useStore((state) => state.currentUser?.username ?? null)`, the same field `Sidebar.jsx`
reads) and picks:

| case | rendered |
| --- | --- |
| `from` equals the current username | `From you` |
| `from` is another non-empty string | `From <from> the user` |
| `from` missing/empty (or whitespace-only) | `From an unidentified user` |
| `kind: "agent"` | `From agent <from>` (unchanged) |
| any other `kind` | `From <from> (unknown kind: <kind>)` (unchanged) |

Wording picked: **`From <from> the user`** — the phrasing suggested in the review. It is
the human counterpart to `From agent <from>`, so a mixed queue reads consistently.
`from` is trimmed for the emptiness check and the label; the username comparison is exact.
With nobody signed in there is no username to match, so a named sender still renders
`From <from> the user` rather than being guessed as yours.

Diff summary (2 files):

- `assets/js/components/InboxPanel.jsx` — `senderLabel(message, currentUsername)` with the
  three user cases above; the component subscribes to `state.currentUser?.username` and
  passes it in; module doc updated.
- `assets/js/components/InboxPanel.test.jsx` — added a `ME` (`"bob"`) constant and seeded
  `currentUser` in `beforeEach` so attribution is deterministic; the two-source test now
  says explicitly that its human entry is the signed-in user. Two new tests:
  "names another human's queued message instead of claiming it as yours" (another sender,
  plus a second render with `currentUser: null` for the no-signed-in-user fallback) and
  "marks a queued user entry with no sender instead of implying it was you" (empty and
  missing `from`, asserting two `From an unidentified user` labels and no `From you`).

### Commands re-run (verbatim)

`cd assets && pnpm vitest run --no-color` — PASS (exit 0). Log: `notes/test-runs/task-d2.log`.

```
 ✓ js/components/InboxPanel.test.jsx (8 tests) 225ms
...
 Test Files  60 passed (60)
      Tests  1176 passed (1176)
   Start at  10:15:55
   Duration  11.07s (transform 7.59s, setup 3.78s, import 21.02s, tests 20.95s, environment 42.03s)
```

`cd assets && pnpm biome check` — PASS (exit 0):

```
Checked 157 files in 74ms. No fixes applied.
```

`cd assets && node lint-file-size.mjs` — PASS (exit 0):

```
OK: no source file exceeds 500 code lines or 700 total lines.
```

### Agreement with the D1 server context

Still no disagreement: D1's `from` for a `kind: "user"` entry is the sending user's
username, which is exactly what this attribution compares against. `kind`/`mode` are
present on every entry and the `{"messages": [...]}` envelope is unchanged.

## Follow-up (consolidated)

Both follow-ups are in the tree; everything below was re-run **after** the final source
edit. Source mtimes: `assets/js/store/slices/agentInbox.js` 10:14:33,
`assets/js/store/index.test.js` 10:14:36, `assets/js/components/InboxPanel.jsx` 10:15:29,
`assets/js/components/InboxPanel.test.jsx` 10:15:47. Verification run 10:33:00–10:33:16.

### What changed

- **`lastIndex` → `-1`.** `retractQueuedOptimistic/2` (`assets/js/store/slices/agentInbox.js`)
  now anchors `lastIndex` at the highest surviving non-optimistic row index, or `-1` when
  no real row survives: the fabricated index must never be reused as the anchor for the
  next optimistic send, and `addChatMessage`'s gap check treats `-1` as "no known rows".
- **`senderLabel` three cases.** `assets/js/components/InboxPanel.jsx` now takes the
  signed-in username (`useStore((state) => state.currentUser?.username ?? null)`):
  equal → `From you`; another non-empty string → `From <from> the user`; missing/empty →
  `From an unidentified user`. `From agent <from>` and the unknown-`kind` call-out are
  unchanged.

### Test names added / changed

- Changed: `store/index.test.js` "leaves lastIndex unchanged when every surviving row is
  optimistic" → **"resets lastIndex to -1 when every surviving row is optimistic"**
  (asserts `-1`, with the rationale in the comment).
- Added (`InboxPanel.test.jsx`): **"names another human's queued message instead of
  claiming it as yours"** (another sender; second render with `currentUser: null` for the
  no-signed-in-user fallback) and **"marks a queued user entry with no sender instead of
  implying it was you"** (empty and missing `from`). Its `beforeEach` now seeds
  `currentUser: { username: "bob" }`; the two-source test's human entry is that user.
- Unchanged but re-verified: the four other `setAgentInbox` retraction tests
  (`store/index.test.js`), which keep a real assistant row at index 0 and so still pin
  `lastIndex === 0`.

### Commands run and verbatim results

`cd assets && pnpm vitest run --no-color` — **PASS** (exit 0), run 10:33:04, log
`notes/test-runs/task-d2.log`:

```
 ✓ js/components/InboxPanel.test.jsx (8 tests) 382ms
 ✓ js/components/ChatInput.test.jsx (64 tests) 828ms
 ✓ js/store/index.test.js (196 tests) 108ms
 ✓ js/pages/ChatPage.test.jsx (74 tests) 874ms
 ✓ js/channels.test.js (169 tests) 9502ms

 Test Files  60 passed (60)
      Tests  1176 passed (1176)
   Start at  10:33:04
   Duration  11.28s (transform 8.07s, setup 4.23s, import 21.60s, tests 21.86s, environment 42.68s)
```

`cd assets && pnpm biome check` — **PASS** (exit 0), run 10:33:00, log
`notes/test-runs/task-d2-biome.log`:

```
Checked 157 files in 73ms. No fixes applied.
```

`cd assets && node lint-file-size.mjs` — **PASS** (exit 0), run 10:33:00:

```
OK: no source file exceeds 500 code lines or 700 total lines.
```

### Still unverified

- The server half (D1) end to end: I only exercise the documented wire shape via mocks, so
  I have not observed a real queue → boundary-delivery → `chat:inbox`-empties cycle.
- The React key in `InboxPanel` is the whole entry tuple; two byte-identical entries in one
  list would still collide (no id on the wire, and `noArrayIndexKey` forbids the index).
- The not-connected-while-busy state still renders a clickable Stop button (unchanged from
  before this task); `disabled` is honoured for the textarea, mode selector and Send.
- Ctrl+M and Ctrl+Up/Down are now live while the agent is busy (a deliberate consequence of
  removing the blanket `isBusy` guard); say so if you want them suppressed.

## review-d2 follow-ups

Accepted items from `notes/review-d2.md` (B1, B2a–d, S3a/b, S4a–d, S5, and the listed
nits). The reviewer's "skip" list was left alone (React key composition,
`Math.max(count, inbox.length)`, `requestInbox`'s error handler, Stop not bound to
`disabled`, the stale `waitingForResponse`).

### Source changes

- **B1** `store/slices/agentCacheMessages.js` — `addUserMessage` fabricates the assistant
  `streaming`/`partial` placeholders only when no accumulator is in flight
  (`cache.streaming || cache.partial`), so a queued send mid-stream no longer destroys the
  live `partial` and the next `chat:delta` is not seen as a gap.
- **B2a/b** new exported pure helper `retractOptimisticRow(cache, content)` in the same
  file: matches the **newest** still-`optimistic` row with that `content`, re-anchors
  `lastIndex` at the highest surviving row index (**optimistic rows included**, `-1` when
  none survive), and clears `streaming`/`partial` only when they sit at
  `removed.index + 1`. `store/slices/agentInbox.js` now applies it once per `kind: "user"`
  entry, so each row is consumed at most once, newest first.
- **B2c** `store/slices/agentCache.js` — `setAgentConnected` strips `optimistic` from the
  rows a reconnect keeps (`withoutOptimistic`), so a row standing in for server state can
  never be retracted later.
- **B2d** the `agentCacheMessages.js` doc no longer claims a real row can never be
  retracted; it states the actual invariant (the marker survives only while the row is
  still a client-side echo).
- **S3a** `pages/ChatPage.jsx` — `agentState === "model_missing"` added to the `frozen`
  list (all five blocked statuses now freeze the composer).
- **S3b** new store method `retractUserMessage(id, content)` (registered in
  `store/index.js`); `channels/agent.js`'s `sendMessage` error path calls it.
  **Deviation from the literal instruction:** it *replaces* `clearPartial` rather than
  being added next to it — with B1 in place a rejected mid-stream send no longer fabricates
  placeholders, so a blind `clearPartial` would wipe the live stream and re-introduce B1 on
  the error path. `retractUserMessage` clears that send's own placeholders and nothing else
  (and is a no-op, same state reference, when no matching row exists).
- **S5** `pages/ChatPage.jsx` — `handleSendMessage` skips the slash-command branch while
  `isAgentBusy`, so `/compact` mid-turn is queued as ordinary chat instead of being pushed,
  cleared, and answered with an error banner.
- **Nits** `components/InboxPanel.jsx` — the unidentified-sender marker now applies to every
  kind (`From an unidentified agent`, `From an unidentified sender (unknown kind: …)`);
  `channels/agent.js` — `statusExtras` forwards `pendingMessageCount`;
  `store/slices/agentInbox.js` — the "skip a re-render" comment corrected to say only
  `messages`/`lastIndex`/`streaming`/`partial` are left alone; `components/ChatInput.jsx` —
  `frozen` docs now name the five blocked statuses instead of `:compacting`, and the
  textarea gets `min-w-0`.

### Tests added / changed

`store/index.test.js` (196 → 200):

- Changed: "pairs each queued user entry with at most one optimistic row, oldest first" →
  **"pairs each queued user entry with the newest matching optimistic row, at most once"**.
  It now asserts that a single entry retracts the newest row (the surviving row is the
  older send), that `lastIndex` stays at the surviving optimistic row's index, and that a
  second two-entry list then retracts both — both queued sends still end up retracted.
- Changed: "resets lastIndex to -1 when every surviving row is optimistic" → **"resets
  lastIndex to -1 when no row survives the retraction"** (with no survivors that is now the
  only `-1` case).
- Changed: the agents-send/non-matching test renamed to **"retracts nothing for an
  agents-send entry or a non-matching user entry (guard, not a feature path)"** with a
  comment saying it passes with the feature removed.
- Added: **"does not clobber an in-flight accumulator when a queued send arrives mid-stream"**
  (same `partial` object, `index`/`charsReceived` intact, next delta
  `{applied: true, needsSync: false}`, then the retraction leaves the accumulator alone).
- Added: **"stops treating a row kept across a reconnect as retractable"**.
- Added: **"retractUserMessage removes the rejected send's optimistic row"** and
  **"retractUserMessage leaves a live stream and other rows alone"** (incl. the no-match
  no-op returning the same cache reference).

`components/ChatInput.test.jsx` (64 → 60):

- Merged the four single-assertion busy-send tests into **"sends while busy through every
  path, but not when not connected"** (form submit, Send click, Ctrl+Enter, then a
  `disabled` re-render for the no-send case).
- Merged the standalone textarea assertion into **"keeps the composer interactive while
  busy: Send alongside Stop, textarea enabled"**.

`components/InboxPanel.test.jsx` (8 → 7):

- Merged the two label tests into **"labels a queued human entry by sender instead of
  assuming it is yours"** (another human, empty `from`, missing `from`, plus a
  no-current-user render).
- Extended **"calls out entries the server did not fully identify"** with an unknown kind
  that has no `from` and an `agent` entry with `from: null`.

`pages/ChatPage.test.jsx` (74 → 80):

- Changed: **"does not send while the agent is busy but the channel is not connected"** now
  types, clicks the disabled Send button and submits the form directly, so the assertion is
  no longer vacuous.
- Added: a **"ChatPage composer freeze"** describe with one test per blocked status
  (`model_missing`, `needs_repair`, `context_overflow`, `compaction_failed`,
  `compaction_loop_detected`) asserting the composer is hidden.
- Added: **"queues a slash command as chat text while the agent is busy"**.

`channels.test.js` (169 → 170):

- Added: **"forwards pendingMessageCount from chat:status so a missed inbox push does not
  stale the count"**.
- Changed: "should handle message send error - clear partial and call onError" →
  **"…retract the optimistic echo, clear partial, and call onError"**, now also asserting
  `messages` is empty and `streaming` is null after the rejection.

No assertion was deleted: every assertion removed from a merged test moved into the merged
test, and the two renamed tests re-point their assertions at the new intent.

### Commands run and verbatim results

`cd assets && pnpm vitest run --no-color` — **PASS** (exit 0), log
`notes/test-runs/task-d2.log`:

```
 ✓ js/store/index.test.js (200 tests) 154ms
 ✓ js/components/InboxPanel.test.jsx (7 tests) 316ms
 ✓ js/components/ChatInput.test.jsx (60 tests) 776ms
 ✓ js/pages/ChatPage.test.jsx (80 tests) 763ms
 ✓ js/channels.test.js (170 tests) 9554ms

 Test Files  60 passed (60)
      Tests  1182 passed (1182)
   Start at  10:50:11
   Duration  11.44s (transform 9.23s, setup 4.39s, import 23.59s, tests 21.24s, environment 44.93s)
```

`cd assets && pnpm biome check` — **PASS** (exit 0), log
`notes/test-runs/task-d2-biome.log`:

```
Checked 157 files in 70ms. No fixes applied.
```

`cd assets && node lint-file-size.mjs` — **PASS** (exit 0):

```
OK: no source file exceeds 500 code lines or 700 total lines.
```

Not on the required list, but run to check the coverage rule, `cd assets && pnpm vitest run
--coverage --no-color` — **PASS** (exit 0), log `notes/test-runs/task-d2-coverage.log`:

```
 Test Files  60 passed (60)
      Tests  1182 passed (1182)
 All files          |    96.3 |    90.82 |    94.7 |   97.23 |
  InboxPanel.jsx   |     100 |      100 |     100 |     100 |
  agentInbox.js    |     100 |      100 |     100 |     100 |
```

(Baseline from the review: All files 96.26 stmts / 90.62 branch, `agentInbox.js` 86.2
branch with lines 53-54 uncovered. The previously uncovered surviving-optimistic-row branch
is now covered by the newest-first test.)

### Unverified / notes

- The server half (D1) is still only exercised through mocks; no real queue →
  boundary-delivery → `chat:inbox`-empties cycle was observed.
- **B2c has a visible consequence:** a reconnect (`init`) that lands between a queued send
  and its `chat:inbox` clears the `optimistic` marker, so that send's retraction no longer
  happens; the queued text then renders only once the next `chat:inbox`/init supplies the
  list, and the delivered real message reconciles by index. This is the trade the review
  asked for (a join is authoritative), not a bug I can verify away client-side.
- Two intermediate failures during development, both fixed and re-run clean: one new store
  test's fixture omitted `content` on the seeded assistant row; and `biome check` reported a
  format-only diff in `store/index.js` after the import edit, fixed with
  `pnpm biome check --write js/store/index.js` (no config touched).
- `retractUserMessage`'s no-match path deliberately returns the same state object (no
  re-render); the error path no longer calls `clearPartial` (see the S3b deviation above).
