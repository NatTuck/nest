/**
 * The phone's top bar: the hamburger that opens the navigation drawer, and the
 * app's name.
 *
 * Phone only (`lg:hidden`), and it owns no state — the drawer's open/closed
 * state is `Layout`'s, because the drawer and this bar are two halves of one
 * control. `triggerRef` is the button, so the drawer can put focus back on the
 * control that opened it when it closes.
 *
 * It sits *above* `main` in the column, so it costs the page the height it
 * takes rather than covering the top of it. On a phone the insets are real
 * (`viewport-fit=cover` in the root layout): `env(safe-area-inset-top)` is the
 * notch or the status bar, and `min-h-14` keeps the bar itself at its designed
 * height below it instead of squeezing the button.
 *
 * The hamburger is 44×44 — the smallest target a thumb hits reliably — and
 * `aria-expanded` is the drawer's state, so the control reports what it did.
 */

export function PhoneTopBar({ expanded, onOpen, triggerRef }) {
  return (
    <header className="flex shrink-0 items-center gap-1 border-b border-gray-200 bg-white px-2 pt-[env(safe-area-inset-top)] lg:hidden">
      <button
        ref={triggerRef}
        type="button"
        onClick={onOpen}
        aria-label="Open navigation"
        aria-expanded={expanded}
        aria-controls="phone-navigation"
        className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-gray-700 transition-colors hover:bg-gray-100 active:bg-gray-200"
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
      <span className="text-lg font-bold text-gray-800">Nest</span>
    </header>
  );
}

export default PhoneTopBar;
