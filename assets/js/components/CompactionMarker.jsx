/**
 * Compaction marker — a divider rendering a single
 * "N archived messages" boundary in the chat timeline.
 *
 * The backend emits a chat:compaction event whenever the agent
 * compacts its context. The marker carries `archivedCount` (the
 * number of messages that were moved to history at this boundary)
 * and `index` (the message index the marker occupies in the
 * monotonic sequence).
 *
 * Clicking the expand button reveals the full collapsed history
 * (the messages moved to the agent's `history` field), rendered
 * by `CollapsedHistory`. Clicking again collapses it. The state
 * is local (a useState in this component) — re-renders start
 * collapsed.
 *
 * The component renders nothing when `marker` is null/undefined
 * or has a non-positive `archivedCount`. It also does nothing
 * when `history` is empty (the user-agent has nothing to show).
 */

import { useState } from "react";
import { CollapsedHistory } from "./CollapsedHistory";

function ChevronDown({ rotated = false }) {
  return (
    <svg
      className={`w-3 h-3 transition-transform ${rotated ? "rotate-180" : ""}`}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M19 9l-7 7-7-7"
      />
    </svg>
  );
}

function ArchiveIcon() {
  return (
    <svg
      className="w-4 h-4"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M5 8h14M5 8a2 2 0 012-2h10a2 2 0 012 2m-14 0v10a2 2 0 002 2h10a2 2 0 002-2V8m-9 4h4"
      />
    </svg>
  );
}

export function CompactionMarker({ marker, history }) {
  const [isExpanded, setIsExpanded] = useState(false);

  if (!marker?.archivedCount || marker.archivedCount <= 0) {
    return null;
  }

  if (!history || history.length === 0) {
    return null;
  }

  const count = marker.archivedCount;
  const label = isExpanded
    ? "Hide archived messages"
    : `Show ${count} archived message${count === 1 ? "" : "s"}`;

  return (
    <div
      data-testid="compaction-marker"
      data-marker-index={marker.index}
      data-archived-count={count}
      className="flex items-center gap-3 px-4 py-2 my-2 mx-8 rounded-lg bg-amber-50/40 border border-amber-200/60"
    >
      <div className="text-amber-600 flex-shrink-0" aria-hidden="true">
        <ArchiveIcon />
      </div>

      <div className="flex-1 min-w-0">
        <div className="text-xs text-amber-700 font-medium">
          Context compacted
        </div>
        <div className="text-[11px] text-amber-600/80">
          {count} earlier message{count === 1 ? "" : "s"} archived
        </div>
      </div>

      <button
        type="button"
        onClick={() => setIsExpanded((v) => !v)}
        aria-expanded={isExpanded}
        aria-label={label}
        data-testid="compaction-marker-toggle"
        className="text-xs font-medium text-amber-700 hover:text-amber-800 flex items-center gap-1"
      >
        <ChevronDown rotated={isExpanded} />
        {isExpanded ? "Hide" : `Show (${count})`}
      </button>

      {isExpanded && (
        <div className="basis-full mt-2">
          <CollapsedHistory history={history} />
        </div>
      )}
    </div>
  );
}
