/**
 * The "we are still joining this agent" affordance for the sidebar tree
 * (#52). It renders in the slot the status dot occupies.
 *
 * A row's status dot answers "what is this agent doing?" from the server's
 * point of view. Between the click and the channel's `init` reply there is
 * nothing from the server yet, and for a cold agent that window can be
 * seconds long — its process may have to start, and its cache then fills in
 * batch by batch. A spinner there is the honest answer: the click registered
 * and we are waiting, rather than a status from the list that the click did
 * not change and that says nothing about the row the user just picked.
 */

/**
 * @param {object} props
 * @param {string} [props.className] — size/spacing classes for the caller's
 *   layout (`w-2 h-2` in the sidebar, matching `StatusDot`).
 */
export function PendingDot({ className = "" }) {
  return (
    <div
      className={`rounded-full flex-shrink-0 animate-spin border-2 border-gray-300 border-t-blue-600 ${className}`}
      role="img"
      aria-label="Connecting"
      title="Connecting"
    />
  );
}

export default PendingDot;
