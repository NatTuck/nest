# Issue #6 — Can't scroll up during streaming (plan)

> Produced by a planning minion, read-only. Pending team-lead review.

## Goal
Make a user's scroll-up (PgUp, wheel, scrollbar drag, touch) immediately stop auto-scrolling so the user can read while content keeps streaming, and re-enable auto-scroll only when the user returns to the bottom.

## Root cause (with evidence)
The hook decides "is the user at the bottom?" with a 300px slop, and re-pins on every new token whenever that slop says "yes":

- `assets/js/hooks/useScrollToBottom.js:3` — `const BOTTOM_THRESHOLD_PX = 300;`
- `assets/js/hooks/useScrollToBottom.js:56-64` — `checkAtBottom` computes `scrollHeight - scrollTop - clientHeight < BOTTOM_THRESHOLD_PX` and sets `isAtBottom`.
- `assets/js/hooks/useScrollToBottom.js:75-82` — on every `trigger` change (each streaming delta), if `isAtBottom` is true it calls `messagesEndEl.scrollIntoView({ behavior: "auto" })`, yanking the view back down.

Consequence: a PgUp or wheel scroll that moves the viewport less than 300px from the bottom leaves `isAtBottom === true`, so the very next streamed token scrolls the user back to the bottom. The slop is what defeats the scroll-up. (The slop likely existed to tolerate content-growth vs. scroll-event lag, so any fix must not reintroduce that false-positive; see design below.)

Wiring: the hook is called in `assets/js/pages/ChatPage.jsx:292-297`, its outputs flow to `ChatComposer` at `assets/js/pages/ChatPage.jsx:588-590`, and the button visibility gate is `hasNewContent && !isAtBottom` in `assets/js/components/ChatComposer.jsx:30`. The scroll container is `assets/js/components/ChatMessages.jsx:33-36` and the anchor is `ChatMessages.jsx:74`.

Nothing is partially fixed; the slop is the whole bug.

## Design: an explicit at-bottom flag driven by scroll direction
Keep the existing `isAtBottom` state as the flag (`useScrollToBottom.js:45`). Change only *how it is updated*:

- On every `scroll` event, compute `distanceFromBottom = scrollHeight - scrollTop - clientHeight` and compare the current `scrollTop` to the previous one.
  - If `distanceFromBottom <= AT_BOTTOM_EPSILON_PX` → set `isAtBottom = true`, clear `hasNewContent`.
  - Else if `scrollTop < previousScrollTop` (a real user scroll-up) → set `isAtBottom = false`.
  - Else do nothing (content grew, or a programmatic downward scroll).
- **Why direction, not just a small threshold:** while streaming, content can grow between a `scrollIntoView` and the scroll event being processed, so a pure distance check would briefly see a large distance and falsely conclude the user scrolled up. Content growth does not change `scrollTop`, and our programmatic `scrollIntoView` only ever *increases* `scrollTop`; only genuine user scroll-up decreases it. Direction detection therefore un-pins on any user scroll-up (fixing the bug) without false positives (preserving auto-follow).
- **Reset:** the flag re-sets to `true` in the same scroll handler when `distanceFromBottom <= epsilon` (user reaches bottom, or the smooth `jumpToBottom` finishes), and in the `useLayoutEffect` at `useScrollToBottom.js:87-92` on mount / `id` change. `hasNewContent` is cleared in both places.

## Ordered tasks
1. **Rewrite the scroll handler in `assets/js/hooks/useScrollToBottom.js`.**
   - Replace `BOTTOM_THRESHOLD_PX = 300` (line 3) with `const AT_BOTTOM_EPSILON_PX = 2;`.
   - In the effect at lines 53-70, track `let lastScrollTop = scrollContainerEl.scrollTop;` in the effect closure, and replace `checkAtBottom` (lines 56-64) with the direction-aware handler described above. Always update `lastScrollTop = scrollTop` after deciding. Keep the passive listener and the `[id, scrollContainerEl]` deps.
   - Update the JSDoc block (lines 5-16) and the inline comment (lines 48-51) to describe the new semantics.
   - **Acceptance:** any scroll event with a smaller `scrollTop` and `distanceFromBottom > epsilon` sets `isAtBottom = false`; a scroll event with unchanged/increased `scrollTop` and a large distance leaves `isAtBottom` untouched; reaching `distanceFromBottom <= epsilon` sets it true and clears `hasNewContent`.
2. **Leave `jumpToBottom` (lines 94-98) unchanged** (only `setHasNewContent(false)`). Do **not** optimistically set `isAtBottom = true` there: `isAtBottom` is a dependency of the auto-scroll effect (line 82), so setting it would re-run that effect and call `scrollIntoView({ behavior: "auto" })`, instantly overriding the smooth scroll. The handler flips the flag to true when the smooth scroll reaches the bottom.
3. **Update `assets/js/hooks/useScrollToBottom.test.js`.**
   - Change the test helper `setupContainer` default to start at the bottom (`scrollTop: 500` with the existing `scrollHeight: 1000`, `clientHeight: 500`) so the hook's documented "assume at bottom on mount" matches the fixture; document why. This lets the existing "scroll up" tests keep using `setMetrics(container, { scrollTop: 0, ... })` as the scroll-up.
   - Delete "treats being within 300px of the bottom as at-bottom" (lines 97-108) — it asserts the buggy slop.
   - Keep/adjust "flips isAtBottom to false…" (110-121) and "…back to true…" (123-144) so the scroll-up starts from the bottom.
   - Adjust the `hasNewContent` tests (163-218) and `jumpToBottom` (222-254) and `id` reset (258-278) to scroll up from the bottom first.
   - Fix the two "ref handling" tests (287-373): the late-mounted container must start at the bottom (pass `scrollTop: 500` to `setupContainer`) before the simulated scroll-up, otherwise the direction baseline is wrong.
4. **Add the key regression tests** (same file):
   - *"a small scroll-up un-pins auto-scroll"* — start at bottom, scroll up by e.g. 20px (well inside the old 300px slop), assert `isAtBottom === false`; then rerender with a new `trigger` and assert `scrollIntoView` was **not** called and `hasNewContent === true`.
   - *"content growth while at the bottom does not un-pin"* — start at bottom, `setMetrics` with a larger `scrollHeight` and unchanged `scrollTop`, fire scroll, assert `isAtBottom` stays `true`; rerender a new `trigger` and assert `scrollIntoView` **was** called.
5. **No changes needed** in `ChatComposer.jsx`, `ChatMessages.jsx`, or `ChatPage.jsx` — the hook's contract (`{ isAtBottom, hasNewContent, jumpToBottom }`) is unchanged.

## Tests to add/update (exact files)
- `assets/js/hooks/useScrollToBottom.test.js` (only file changed besides the hook). New assertions as in tasks 3-4; the two new regression tests directly encode the issue's acceptance criteria.
- `assets/js/components/ChatComposer.test.jsx` already covers the button gate (`hasNewContent && !isAtBottom`); no change required.
- `assets/js/pages/ChatPage.test.jsx` mocks the hook, so it is unaffected functionally; do not touch it for this fix.

## Edge cases and risks
- **Content growth vs. scroll-event lag** (the reason the slop existed): handled because growth does not change `scrollTop`; only a real up-scroll decreases it.
- **Programmatic scrolls** (`scrollIntoView` on mount/id/new content) only increase `scrollTop`, so they never un-pin.
- **Fractional/sub-pixel `scrollTop`**: `AT_BOTTOM_EPSILON_PX = 2` absorbs rounding; exact `0` could miss.
- **Rubber-band overscroll / already-at-top**: `distanceFromBottom <= epsilon` (possibly negative) is treated as at-bottom, which is harmless.
- **Non-scrollable container**: distance ≤ 0, always at-bottom — correct.
- **Smooth `jumpToBottom`**: flag flips true when the animation reaches bottom via the handler; setting it eagerly would cancel the smooth scroll (see task 2).
- **Keyboard/wheel/scrollbar/touch** are all covered since we listen to `scroll`; a PgUp that scrolls the window instead of the container is not detectable, but the layout (`h-full` page + `flex-1 overflow-y-auto` container) makes the container the scroller.
- **Pre-existing smell (out of scope)**: `ChatPage.test.jsx:72-74` mocks the hook as `() => [vi.fn(), null]` (an array), so the real object return shape is never validated there.

## Verification steps (do not run during planning)
1. Quick loop: `cd assets && pnpm vitest run js/hooks/useScrollToBottom.test.js`.
2. Full JS suite + coverage thresholds (90% lines/functions/branches/statements, `assets/vite.config.ts:29-38`): `mix assets.test`.
3. Lints/size: `mix assets.check`.
4. `mix precommit` and read the **entire** output (redirect to a file under `notes/test-runs/` if long; never grep/head/tail it).
5. Manually confirm in the running app (user-managed dev server): start a stream, press PgUp / wheel up mid-stream, verify it stops auto-scrolling and the "Jump to latest" button appears; click it (or scroll to bottom) and verify auto-scroll resumes.

## Open questions / decisions
- **Button timing**: the auto-scroll effect depends on `isAtBottom` (line 82), so today scrolling up sets `hasNewContent = true` immediately (button appears before any new content). Keep that, or change the effect to only set `hasNewContent` on real `trigger` changes (drop `isAtBottom` from its deps) so the button appears only once new content actually arrives? This is a UX call; the minimal fix keeps current behavior.
- **Epsilon value**: 2px proposed; is exact `0` preferred, or a slightly larger tolerance for unusual CSS/layout gaps?
- No dependency on other open issues is apparent.
