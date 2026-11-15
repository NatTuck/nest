/**
 * The phone's top bar: the hamburger that opens the navigation drawer, a slot
 * for the page's own chrome, and the app's name when nothing has claimed it.
 *
 * Phone only (`lg:hidden`), and it owns no state — the drawer's open/closed
 * state is `Layout`'s, because the drawer and this bar are two halves of one
 * control. `triggerRef` is the button, so the drawer can put focus back on the
 * control that opened it when it closes.
 *
 * ## The slot
 *
 * `slotRef` is an empty element the current page can fill through
 * `PhoneBarSlotContext` (a portal). The chat page puts the agent's name, its
 * status dot, the disclosure and the waiting badge in it, so that page spends
 * **one** row on chrome instead of two — its own header row was a second 44px
 * band under this one, and on a phone that band is a message and a half.
 *
 * The brand hides itself when the slot is filled, by a stylesheet rule on
 * `:empty` rather than by state: the bar stays a presentational component, and
 * there is no ordering problem between "the page mounted" and "the brand goes
 * away".
 *
 * It sits *above* `main` in the column, so it costs the page the height it
 * takes rather than covering the top of it. On a phone the insets are real
 * (`viewport-fit=cover` in the root layout): `env(safe-area-inset-top)` is the
 * notch or the status bar, and the 44px hamburger keeps the bar at a thumb's
 * height below it.
 *
 * The hamburger is 44×44 — the smallest target a thumb hits reliably — and
 * `aria-expanded` is the drawer's state, so the control reports what it did.
 */

export function PhoneTopBar({ expanded, onOpen, triggerRef, slotRef }) {
  return (
    <header className="flex shrink-0 items-start gap-1 border-b border-gray-200 bg-white px-2 pt-[env(safe-area-inset-top)] lg:hidden">
      <button
        ref={triggerRef}
        type="button"
        onClick={onOpen}
        aria-label="Open navigation"
        aria-expanded={expanded}
        aria-controls="phone-navigation"
        className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg text-gray-700 transition-colors hover:bg-gray-100 active:bg-gray-200"
      >
        <svg
          className="h-6 w-6"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M4 6h16M4 12h16M4 18h16"
          />
        </svg>
      </button>
      {/* Empty on every page but the chat page, which portals its own chrome in
          here. `:empty` is what tells the stylesheet to drop the brand. */}
      <div
        ref={slotRef}
        id="phone-bar-slot"
        className="phone-bar-slot flex min-w-0 flex-1 flex-col"
      />
      <span className="phone-bar-brand flex h-11 items-center text-lg font-bold text-gray-800">
        Nest
      </span>
    </header>
  );
}

export default PhoneTopBar;
