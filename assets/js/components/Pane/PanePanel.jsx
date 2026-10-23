/**
 * PanePanel — the chat page's right-hand pane: the open agent's TODO list
 * (#120) and the space's questions for the user (#119).
 *
 * It is a sibling of the conversation column, not part of it: the conversation
 * is the page's one scroll container (issue #86), and a pane inside it would
 * either scroll the questions away with the transcript or take the transcript's
 * height. On a wide screen the pane is a fixed-width column beside the chat; on
 * a narrow one it is an overlay over the chat, which is why the page's root is
 * the positioning context.
 *
 * The pane starts **closed**, and closing it is the user's state: it lives in
 * the store, so it survives a navigation. A frame opens it only when a question
 * arrives that the pane was not already showing — and, on the first frame for a
 * space, when something is already waiting. A frame that only repeats what is on
 * screen, or that changes a TODO list, leaves it shut: otherwise closing it
 * would be undone by the next unrelated frame, and a user who is not ready to
 * answer could not dismiss the question they can see on the indicator.
 *
 * The toggle is on screen whenever the pane is closed, whether or not anything
 * is waiting, and it is an **overlay** at every width rather than a column of
 * its own — a closed pane must not take width from the conversation. Hiding it when nothing is waiting made closing a one-way door:
 * with no questions outstanding there was no control left that could reopen it,
 * and a TODO list written afterwards was invisible and unreachable. What the
 * waiting count buys is the *notification* — the amber pill and the dot — so a
 * closed pane with nothing outstanding is a quiet grey control instead.
 *
 * With no frame for this space there is nothing to show yet, and rendering an
 * empty column would shove the chat sideways the moment the first frame landed.
 */

import { useStore } from "../../store";
import { outstandingCount } from "../../store/slices/pane";
import { DecisionsAccordion } from "./DecisionsAccordion";
import { TodoList } from "./TodoList";

export function PanePanel({ name, spaceId }) {
  const pane = useStore((state) => state.panes?.[spaceId]);

  if (!pane) return null;

  const outstanding = outstandingCount(pane);

  if (pane.collapsed) {
    const waiting = outstanding > 0;

    return (
      <button
        type="button"
        title="Show the pane"
        onClick={() => useStore.getState().setPaneCollapsed(spaceId, false)}
        className={[
          "absolute right-3 top-3 z-30 flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold shadow-md transition-colors",
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

  return (
    <aside
      aria-label="Questions and TODO"
      className="absolute inset-y-0 right-0 z-20 flex w-full max-w-md flex-col overflow-hidden border-l border-gray-200 bg-white shadow-xl lg:static lg:z-auto lg:w-96 lg:max-w-none lg:shrink-0 lg:shadow-none"
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

      <div className="min-h-0 flex-1 overflow-y-auto">
        <TodoList todos={pane.todos} agentName={name} />
        <DecisionsAccordion name={name} spaceId={spaceId} />
      </div>
    </aside>
  );
}
