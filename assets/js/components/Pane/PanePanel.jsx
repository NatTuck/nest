/**
 * PanePanel — the chat page's right-hand pane: the open agent's TODO list
 * (#120) and the space's questions for the user (#119).
 *
 * It is a sibling of the conversation column, not part of it: the conversation
 * is the page's one scroll container (issue #86), and a pane inside it would
 * either scroll the questions away with the transcript or take the transcript's
 * height. It is a fixed-width column beside the chat — **desktop only**.
 *
 * Below `lg` the pane is the chat page's third tab instead (#169): the tab
 * renders `PaneContent` in the main column, and the `collapsed` state below
 * stays the *desktop* mechanism. The reason is that the two controls are
 * different questions. A phone has no column to give away, so "is the pane
 * open?" is answered by which tab is selected; a `pane:state` frame may open the
 * pane (see the slice), and on a phone that would mean a question sliding over
 * the conversation the reader is in the middle of. Hence `hidden lg:flex`: the
 * sibling column simply does not exist below `lg`, and the tab does.
 *
 * The pane starts **closed**, and closing it is the user's state: it lives in
 * the store, so it survives a navigation. A frame opens it only when a question
 * arrives that the pane was not already showing — and, on the first frame for a
 * space, when something is already waiting. A frame that only repeats what is on
 * screen, or that changes a TODO list, leaves it shut: otherwise closing it
 * would be undone by the next unrelated frame, and a user who is not ready to
 * answer could not dismiss the question they can see on the indicator.
 *
 * The control that opens it on a desktop is `PaneToggle`, in the tab bar's
 * trailing slot — see that module for why it lives there and for what the
 * waiting count means.
 *
 * With no frame for this space there is nothing to show yet, and rendering an
 * empty column would shove the chat sideways the moment the first frame landed.
 */

import { useStore } from "../../store";
import { PaneContent } from "./PaneContent";

export function PanePanel({ name, spaceId }) {
  const pane = useStore((state) => state.panes?.[spaceId]);

  if (!pane) return null;

  // The toggle that opens it is `PaneToggle`, in the tab bar's trailing slot
  // (#169): a closed pane must not take a column beside the conversation.
  if (pane.collapsed) return null;

  return (
    <aside
      aria-label="Questions and TODO"
      className="hidden flex-col overflow-hidden border-l border-gray-200 bg-white lg:flex lg:w-96 lg:shrink-0"
    >
      <div className="flex shrink-0 items-center justify-between border-b border-gray-200 px-3 py-1.5">
        <span className="text-[11px] font-semibold uppercase tracking-wider text-gray-400">
          Pane
        </span>
        <button
          type="button"
          onClick={() => useStore.getState().setPaneCollapsed(spaceId, true)}
          className="rounded px-1.5 py-0.5 text-xs font-medium text-gray-500 transition-colors hover:bg-gray-100 hover:text-gray-800"
        >
          Hide pane
        </button>
      </div>

      <PaneContent name={name} spaceId={spaceId} />
    </aside>
  );
}
