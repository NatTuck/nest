/**
 * The coloured status dot shared by the sidebar's agent rows and the space
 * view's agent cards (#53). Keeping it one component means both surfaces
 * agree on the colour, the tooltip, and the accessible name.
 *
 * The mapping itself lives in `js/utils/agentStatus.js`; this component only
 * renders it.
 */

import { agentStatusDot } from "../utils/agentStatus";

/**
 * @param {object} props
 * @param {string | null | undefined} props.status — the agent's observable
 *   status, as broadcast by the server.
 * @param {string} [props.className] — size/spacing classes for the caller's
 *   layout (`w-2 h-2` in the sidebar, `w-2.5 h-2.5` in the space view).
 */
export function StatusDot({ status, className = "" }) {
  const dot = agentStatusDot(status);

  return (
    <div
      className={`rounded-full flex-shrink-0 ${className} ${dot.className}`}
      role="img"
      aria-label={dot.label}
      title={dot.label}
    />
  );
}

export default StatusDot;
