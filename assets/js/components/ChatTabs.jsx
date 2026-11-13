/**
 * The chat page's view switcher, in the two shapes the two layouts need.
 *
 * * `ChatTabs` — the bar under the chrome, **desktop only** (`max-lg:hidden`).
 *   It is `shrink-0` chrome the conversation cannot squeeze and the band the
 *   pane's toggle (#169) lives in.
 * * `PhoneTabs` — the same views as a compact group inside the header's
 *   disclosure (`lg:hidden`). Below `lg` the bar was a whole row above the
 *   conversation, and on a phone that row was ~53px of a ~640px viewport: the
 *   views now open from the chevron, which is the one row the phone keeps.
 *
 * The pane's *tab* is therefore phone-only, and the pane's *toggle* is
 * desktop-only — the same split as before, with the phone's copy moved into the
 * disclosure. Two controls for one view are never on screen at once: the
 * breakpoint decides, in the stylesheet, and no JS reads a width to do it.
 *
 * The pane's waiting signal moved out of both: it is a badge on the header's
 * chevron now (`ChatHeader`), because the tab it used to ride is behind that
 * chevron and a signal you have to open a disclosure to see is not a signal.
 *
 * Extracted from `ChatPage` to keep that file under the source-line cap.
 */

export const CHAT_TAB = "chat";
export const JOBS_TAB = "jobs";
export const PANE_TAB = "pane";

/**
 * A view's short name, with no count: what the header's active-view chip says.
 *
 * One place, because the chip, the bar and the phone's group must not drift into
 * three vocabularies for the same three views.
 */
export function tabName(id) {
  if (id === JOBS_TAB) return "Shell jobs";
  if (id === PANE_TAB) return "Pane";
  return "Chat";
}

/** A view's label, with the job count the jobs view carries. */
export function tabLabel(id, jobCount = 0) {
  return id === JOBS_TAB ? `${tabName(id)} (${jobCount})` : tabName(id);
}

/** The views this page offers: the pane's is only there once a frame arrived. */
function tabIds(hasPane) {
  return hasPane ? [CHAT_TAB, JOBS_TAB, PANE_TAB] : [CHAT_TAB, JOBS_TAB];
}

function tabClass(active) {
  return [
    "inline-flex items-center justify-center rounded-t-md border-b-2 px-3 py-1.5 text-sm font-medium transition-colors duration-150",
    active
      ? "border-blue-600 text-blue-700"
      : "border-transparent text-gray-500 hover:bg-gray-50 hover:text-gray-700",
  ].join(" ");
}

function phoneTabClass(active) {
  return [
    "inline-flex items-center justify-center rounded-md border px-2 py-1 text-xs font-medium transition-colors",
    active
      ? "border-blue-600 bg-blue-50 text-blue-700"
      : "border-gray-300 bg-white text-gray-600 hover:bg-gray-50 active:bg-gray-100",
  ].join(" ");
}

export function ChatTabs({ active, onSelect, jobCount = 0, trailing = null }) {
  return (
    <div
      role="tablist"
      aria-label="Chat views"
      className="mb-4 flex items-center gap-1 border-b border-gray-200 max-lg:hidden"
    >
      {[CHAT_TAB, JOBS_TAB].map((id) => (
        <button
          key={id}
          type="button"
          role="tab"
          aria-selected={active === id}
          onClick={() => onSelect(id)}
          className={tabClass(active === id)}
        >
          {tabLabel(id, jobCount)}
        </button>
      ))}
      {/* The pane's toggle (#169): the bar's right-hand end is the one band with
          nothing under it, and it is chrome the conversation cannot scroll away.
          A closed pane must not cost the conversation a column, and an overlay
          in the chat's corner would cover the header's live status. */}
      {trailing && <div className="ml-auto hidden lg:block">{trailing}</div>}
    </div>
  );
}

/**
 * The phone's copy of the switcher, rendered inside the header's disclosure.
 *
 * `data-testid` is how a test tells it from the desktop bar: both are in the DOM
 * when the disclosure is open, and jsdom applies no stylesheet, so `lg:hidden`
 * and `max-lg:hidden` are just class names to it. In a browser exactly one is
 * ever in the accessibility tree.
 */
export function PhoneTabs({ active, onSelect, jobCount = 0, hasPane = false }) {
  return (
    <div
      role="tablist"
      aria-label="Chat views"
      data-testid="phone-tabs"
      className="flex flex-wrap items-center gap-1 lg:hidden"
    >
      {tabIds(hasPane).map((id) => (
        <button
          key={id}
          type="button"
          role="tab"
          aria-selected={active === id}
          onClick={() => onSelect(id)}
          className={phoneTabClass(active === id)}
        >
          {tabLabel(id, jobCount)}
        </button>
      ))}
    </div>
  );
}
