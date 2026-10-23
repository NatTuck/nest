/**
 * PaneToggle — the control that opens the right-hand pane (#169).
 *
 * It lives in the tab bar's trailing slot rather than beside the conversation.
 * The pane is **closed by default**, so this is the page's default state and it
 * must cost the conversation nothing: as a sibling column it took a vertical
 * strip out of the chat even while closed, and as an overlay in the chat's
 * top-right corner it painted over the header's live status (the token chip and
 * the connection row). The tab bar's right-hand end is empty chrome that is
 * pinned outside the scroll area, so the control sits there without covering
 * anything and without taking a column.
 *
 * It is on screen whenever the pane is closed, whether or not anything is
 * waiting. Hiding it when nothing is waiting made closing a one-way door: with
 * no questions outstanding there was no control left that could reopen it, and a
 * TODO list written afterwards was invisible and unreachable. What the waiting
 * count buys is the *notification* — the amber pill and the dot — so a closed
 * pane with nothing outstanding is a quiet grey control instead.
 *
 * With no frame for this space there is nothing to show yet, and rendering a
 * toggle for a pane that has never sent a frame would offer a control over
 * nothing.
 */

import { useStore } from "../../store";
import { outstandingCount } from "../../store/slices/pane";

export function PaneToggle({ spaceId }) {
  const pane = useStore((state) => state.panes?.[spaceId]);

  if (!pane?.collapsed) return null;

  const outstanding = outstandingCount(pane);
  const waiting = outstanding > 0;

  return (
    <button
      type="button"
      title="Show the pane"
      onClick={() => useStore.getState().setPaneCollapsed(spaceId, false)}
      className={[
        "flex items-center gap-2 rounded-full border px-3 py-1 text-xs font-semibold shadow-sm transition-colors",
        waiting
          ? "border-amber-300 bg-amber-50 text-amber-900 hover:bg-amber-100"
          : "border-gray-300 bg-white text-gray-600 hover:bg-gray-50",
      ].join(" ")}
    >
      {waiting && (
        <span
          className="h-2 w-2 rounded-full bg-amber-500"
          aria-hidden="true"
        />
      )}
      {waiting
        ? `${outstanding} question${outstanding === 1 ? "" : "s"}`
        : "Pane"}
    </button>
  );
}
