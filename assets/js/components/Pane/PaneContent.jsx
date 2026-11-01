/**
 * The pane's body: the open agent's TODO list (#120) and the space's questions
 * for the user (#119), in one scroll region.
 *
 * Extracted from `PanePanel` because the pane has two frames and the body has to
 * be the same in both: the desktop's fixed-width column beside the chat
 * (`PanePanel`), and below `lg` the chat page's third tab, which renders it in
 * the main column instead. Only the frame differs — which column it is, and
 * which control closes it — so the body lives here rather than being copied.
 *
 * It reads the pane's own slice rather than taking it as a prop, so neither
 * frame can render a body for a frame that has not arrived: with no `pane:state`
 * for the space yet there is nothing to show, and an empty list would claim the
 * agent has no TODOs and the space no questions.
 */

import { useStore } from "../../store";
import { DecisionsAccordion } from "./DecisionsAccordion";
import { TodoList } from "./TodoList";

export function PaneContent({ name, spaceId }) {
  const pane = useStore((state) => state.panes?.[spaceId]);

  if (!pane) return null;

  return (
    <div className="min-h-0 flex-1 overflow-y-auto">
      <TodoList todos={pane.todos} agentName={name} />
      <DecisionsAccordion name={name} spaceId={spaceId} />
    </div>
  );
}

export default PaneContent;
