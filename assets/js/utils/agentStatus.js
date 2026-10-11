/**
 * The single mapping from an agent's observable status to the coloured
 * status dot (#53). The sidebar's agent rows and the space view's agent
 * cards both render this dot, so the mapping lives here rather than being
 * duplicated in each surface.
 *
 * The status set mirrors `Nest.Agents.Agent.Machine.status_for/1` — the
 * server's single authority for the observable status:
 *
 *   - the working statuses: `idle`, `streaming`, `executing_tools`,
 *     `compacting`;
 *   - the five blocked statuses (`needs_repair`, `model_missing`,
 *     `context_overflow`, `compaction_failed`, `compaction_loop_detected`)
 *     that are terminal-ish stalls needing an external action to leave.
 *
 * Working statuses pulse so a glance distinguishes "doing something" from
 * "sitting still"; blocked statuses are a static red — a stall is a fact to
 * read, not an activity to watch.
 */

/** Dot classes and label for each known status. */
const STATUS_DOTS = {
  idle: { className: "bg-gray-300", label: "Idle" },
  streaming: { className: "bg-green-500 animate-pulse", label: "Streaming" },
  executing_tools: {
    className: "bg-amber-500 animate-pulse",
    label: "Executing tools",
  },
  compacting: { className: "bg-blue-500 animate-pulse", label: "Compacting" },
  needs_repair: { className: "bg-red-500", label: "Needs repair" },
  model_missing: { className: "bg-red-500", label: "Model missing" },
  context_overflow: { className: "bg-red-500", label: "Context overflow" },
  compaction_failed: { className: "bg-red-500", label: "Compaction failed" },
  compaction_loop_detected: {
    className: "bg-red-500",
    label: "Compaction loop detected",
  },
};

/**
 * The statuses this module knows about, in the order the tests and any
 * legend should present them.
 */
export const AGENT_STATUSES = Object.keys(STATUS_DOTS);

/**
 * Resolve the dot for an agent status.
 *
 * An unrecognised (or missing) status falls back to the neutral idle dot so
 * a status the client has not learned yet renders as "no information"
 * rather than disappearing; the label still names the value so the tooltip
 * is not silently wrong.
 *
 * @param {string | null | undefined} status — the agent's observable status.
 * @returns {{ className: string, label: string }}
 */
export function agentStatusDot(status) {
  if (Object.hasOwn(STATUS_DOTS, status)) {
    return STATUS_DOTS[status];
  }
  return {
    className: "bg-gray-300",
    label: status ? `Unknown status: ${status}` : "Unknown status",
  };
}
