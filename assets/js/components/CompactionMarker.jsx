/**
 * Compaction marker — a divider rendering the boundary between
 * archived and active history.
 *
 * The backend emits a chat:compaction event whenever the agent
 * compacts its context. The marker carries:
 *   * `archivedCount` — number of messages that were moved to
 *     history at this boundary.
 *   * `tokensCompacted` / `tokensCompactedTo` — token-count stats
 *     recorded on the marker at compaction time (the columns
 *     `compaction_tokens_compacted` / `compaction_tokens_compacted_to`
 *     on the `messages` table). Drives the
 *     "Compaction: X tokens compacted to Y (saved Z)" header.
 *     Both optional — `null` for pre-existing marker rows whose
 *     stats weren't recorded; the UI shows
 *     "Context compacted (N archived)" without a token count.
 *   * `index` — the message index the marker occupies in the
 *     monotonic sequence.
 *
 * Clicking the expand button reveals the full collapsed history
 * (the messages moved to the agent's `history` field, plus the
 * marker as the last visible item), rendered by
 * `CollapsedHistory`. Clicking again collapses it. The state
 * is local (a useState in this component) — re-renders start
 * collapsed.
 *
 * The component renders nothing when `marker` is null/undefined,
 * has a non-positive `archivedCount`, or `history` is empty.
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

function formatTokens(tokens) {
  if (typeof tokens !== "number" || !Number.isFinite(tokens)) return null;
  return tokens.toLocaleString("en-US");
}

function buildStatsLine(marker) {
  const compacted = formatTokens(marker.tokensCompacted);
  const compactedTo = formatTokens(marker.tokensCompactedTo);

  if (compacted === null || compactedTo === null) return null;

  return {
    compacted,
    compactedTo,
    saved: formatTokens(compacted - compactedTo),
  };
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

  const stats = buildStatsLine(marker);

  return (
    <div
      data-testid="compaction-marker"
      data-marker-index={marker.index}
      data-archived-count={count}
      data-tokens-compacted={marker.tokensCompacted ?? ""}
      data-tokens-compacted-to={marker.tokensCompactedTo ?? ""}
      className="flex items-center gap-3 px-4 py-2 my-2 mx-8 rounded-lg bg-amber-50/40 border border-amber-200/60"
    >
      <div className="text-amber-600 flex-shrink-0" aria-hidden="true">
        <ArchiveIcon />
      </div>

      <div className="flex-1 min-w-0">
        {stats ? (
          <>
            <div
              className="text-xs text-amber-700 font-medium"
              data-testid="compaction-stats"
            >
              Compaction: {stats.compacted} tokens compacted to{" "}
              {stats.compactedTo}
            </div>
            {Number(marker.tokensCompacted) >=
              Number(marker.tokensCompactedTo) && (
              <div className="text-[11px] text-amber-600/80">
                saved {stats.saved} tokens across {count} earlier message
                {count === 1 ? "" : "s"}
              </div>
            )}
          </>
        ) : (
          <>
            <div className="text-xs text-amber-700 font-medium">
              Context compacted
            </div>
            <div className="text-[11px] text-amber-600/80">
              {count} earlier message{count === 1 ? "" : "s"} archived
            </div>
          </>
        )}
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
