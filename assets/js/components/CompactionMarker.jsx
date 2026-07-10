/**
 * Compaction marker — collapsed/expanded entry into an agent's
 * archived history.
 *
 * The backend broadcasts a chat:compaction event whenever the
 * agent compacts its context. The marker carries:
 *   * `archivedCount` — number of messages that were moved to
 *     history at this boundary.
 *   * `tokensCompacted` / `tokensCompactedTo` — token-count
 *     stats recorded on the marker at compaction time.
 *   * `index` — the message index the marker occupies in the
 *     monotonic sequence.
 *
 * Rendered collapsed: a "History" header with a "Last
 * compaction: X → Y" sub-line (or "N earlier messages archived"
 * when token stats are missing) and a Show/Hide toggle. The
 * Show toggle's count is the TOTAL history length (passed in
 * via the `historyCount` prop), not the marker's
 * `archivedCount` — after multiple compactions the latter only
 * describes the most recent boundary, while the user expects
 * the count of all archived messages they're about to reveal.
 *
 * Rendered expanded: the "Last compaction" sub-line is
 * omitted (the user is already looking at the full message
 * sequence with inline `CompactionMarkerBox` entries that
 * carry the same per-compaction stats, so the redundant
 * summary would just get squished against the toggle
 * button). The "History" title and Hide toggle stay.
 * A `CollapsedHistory` showing every
 * archived message in original index order, with every
 * compaction marker inline. The marker itself does NOT render
 * a duplicate "marker box" in the expanded view (the
 * `CollapsedHistory` renders the marker inline as part of the
 * full sequence, so re-rendering it as a footer would double
 * the boundary visual).
 *
 * `CompactionMarkerBox` is also exported for use by
 * `CollapsedHistory` to render markers inline within the
 * expanded list. Both views use the same data-testid
 * (`history-compaction-marker`) so test selectors can find
 * markers regardless of context.
 */

import { useState } from "react";
import { CollapsedHistory } from "./CollapsedHistory.jsx";

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

// Inline marker box used by `CollapsedHistory` to render every
// `role: "compaction"` entry in the expanded history list. The
// rendering is identical to the (now-removed) footer variant
// from the prior `CollapsedHistory` implementation — the
// difference is just where it's placed (inline in the message
// list vs. as a footer). The `data-testid` matches the
// collapsed-history test selectors so existing assertions still
// pass.
export function CompactionMarkerBox({ marker }) {
  const count = marker.archivedCount ?? 0;
  const compacted = formatTokens(marker.tokensCompacted);
  const compactedTo = formatTokens(marker.tokensCompactedTo);
  const hasStats = compacted !== null && compactedTo !== null;
  const saved =
    hasStats && formatTokens(marker.tokensCompacted - marker.tokensCompactedTo);

  return (
    <div
      data-testid="history-compaction-marker"
      data-marker-index={marker.index}
      className="flex gap-3 p-3 rounded-lg border bg-amber-50 border-amber-300/60"
    >
      <div
        className="w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0 text-xs font-medium bg-amber-500 text-white"
        aria-hidden="true"
      >
        C
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-2 mb-1">
          <span className="font-medium text-xs text-amber-800">Compaction</span>
          {marker.occurredAt && (
            <span className="text-[10px] text-amber-700/80">
              {formatTimestamp(marker.occurredAt)}
            </span>
          )}
        </div>
        {hasStats ? (
          <>
            <div
              className="text-xs text-amber-800"
              data-testid="history-compaction-stats"
            >
              Compaction: {compacted} tokens compacted to {compactedTo}
            </div>
            {marker.tokensCompacted >= marker.tokensCompactedTo && (
              <div className="text-[11px] text-amber-700/80">
                saved {saved} tokens across {count} earlier message
                {count === 1 ? "" : "s"}
              </div>
            )}
          </>
        ) : (
          <div className="text-xs text-amber-800">
            {count} earlier message{count === 1 ? "" : "s"} archived
          </div>
        )}
      </div>
    </div>
  );
}

function formatTimestamp(ts) {
  if (!ts) return null;
  return new Date(ts).toLocaleString();
}

export function CompactionMarker({ marker, history, historyCount }) {
  const [isExpanded, setIsExpanded] = useState(false);

  if (!marker?.archivedCount || marker.archivedCount <= 0) {
    return null;
  }

  if (!history || history.length === 0) {
    return null;
  }

  // The Show/Hide toggle reports the TOTAL history length, not
  // the most-recent marker's `archivedCount` — after multiple
  // compactions the latter only describes one boundary while
  // the user is about to see every archived message in the
  // expansion.
  const count =
    typeof historyCount === "number" ? historyCount : history.length;
  const label = isExpanded
    ? "Hide archived messages"
    : `Show ${count} archived message${count === 1 ? "" : "s"}`;

  const stats = buildStatsLine(marker);
  const lastArchived = marker.archivedCount ?? 0;

  return (
    <div
      data-testid="compaction-marker"
      data-marker-index={marker.index}
      data-archived-count={marker.archivedCount}
      data-tokens-compacted={marker.tokensCompacted ?? ""}
      data-tokens-compacted-to={marker.tokensCompactedTo ?? ""}
      className="my-2 mx-8 rounded-lg bg-amber-50/40 border border-amber-200/60"
    >
      {/* Header row: icon + title (+ sub-line when collapsed).
          The toggle button is on its OWN row below so the
          "History" title and the button never compete for
          horizontal space (the previous flex-row layout
          squished the title against the button). */}
      <div className="flex items-center gap-3 px-4 pt-2">
        <div className="text-amber-600 flex-shrink-0" aria-hidden="true">
          <ArchiveIcon />
        </div>
        <div className="flex-1 min-w-0">
          <div
            className="text-sm text-amber-800 font-medium"
            data-testid="compaction-marker-title"
          >
            History
          </div>
          {/* The "Last compaction" sub-line is only shown when
              collapsed. When expanded, the user is already
              looking at the full message sequence (with inline
              `CompactionMarkerBox` entries that carry the same
              per-compaction stats), so the redundant summary
              isn't needed. */}
          {!isExpanded &&
            (stats ? (
              <div
                className="text-[11px] text-amber-700/80"
                data-testid="compaction-marker-subtitle"
              >
                Last compaction: {stats.compacted} tokens compacted to{" "}
                {stats.compactedTo}
                {Number(marker.tokensCompacted) >=
                  Number(marker.tokensCompactedTo) && (
                  <>
                    {" "}
                    · saved {stats.saved} across {lastArchived} earlier message
                    {lastArchived === 1 ? "" : "s"}
                  </>
                )}
              </div>
            ) : (
              <div
                className="text-[11px] text-amber-700/80"
                data-testid="compaction-marker-subtitle"
              >
                Last compaction · {lastArchived} earlier message
                {lastArchived === 1 ? "" : "s"} archived
              </div>
            ))}
        </div>
      </div>

      {isExpanded && (
        <div className="px-4 pt-2">
          <CollapsedHistory history={history} />
        </div>
      )}

      {/* Toggle button: on its own row, right-aligned. The
          `mt-2` adds breathing room between the header (or
          expanded history) and the button. */}
      <div className="flex justify-end px-4 pb-2 mt-2">
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
      </div>
    </div>
  );
}
