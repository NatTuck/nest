/**
 * CollapsedHistory — renders the archived messages that were
 * moved to the agent's `history` field by compaction.
 *
 * Renders read-only message bubbles (no edit / re-send), with a
 * muted style that signals "this is older context, not part of
 * the current conversation."
 *
 * Early compaction markers (`role: "compaction"`) are filtered
 * out — the parent's `<CompactionMarker>` divider already
 * represents the most recent boundary. The LAST compaction
 * marker IS rendered, but as a dedicated "marker box" at the
 * end of the visible list (the marker carries the
 * `tokensCompacted` / `tokensCompactedTo` stats the divider
 * does not, plus the archived count and summary). The user can
 * see the actual state — the message list ends with the marker.
 *
 * Long message content is rendered as-is (no truncation here).
 * Tool calls and tool results are surfaced so the reader can see
 * what the agent did before compaction.
 */

import { MessageContent } from "./MessageContent";
import { ThinkingBlock } from "./ThinkingBlock";
import { stripModePrefix } from "../utils/stripModePrefix.js";

const ROLE_LABELS = {
  user: "You",
  assistant: "Assistant",
  system: "System",
  tool: "Tool Result",
};

const ROLE_STYLES = {
  user: "bg-blue-50/60 border-blue-200/60",
  assistant: "bg-gray-50 border-gray-200",
  system: "bg-amber-50/60 border-amber-200/60",
  tool: "bg-green-50/60 border-green-200/60",
};

const AVATAR_STYLES = {
  user: "bg-blue-600 text-white",
  assistant: "bg-gray-600 text-white",
  system: "bg-amber-500 text-white",
  tool: "bg-green-500 text-white",
};

const AVATAR_LETTER = {
  user: "U",
  assistant: "AI",
  system: "S",
  tool: "T",
};

function formatTimestamp(ts) {
  if (!ts) return null;
  return new Date(ts).toLocaleString();
}

function formatTokens(tokens) {
  if (typeof tokens !== "number" || !Number.isFinite(tokens)) return null;
  return tokens.toLocaleString("en-US");
}

function MessageBubble({ message }) {
  const role = message.role;
  const label = ROLE_LABELS[role] || role;
  const className = ROLE_STYLES[role] || "bg-gray-50 border-gray-200";
  const avatarClass = AVATAR_STYLES[role] || "bg-gray-600 text-white";
  const letter = AVATAR_LETTER[role] || "?";

  return (
    <div
      data-testid="history-message"
      data-role={role}
      className={`flex gap-3 p-3 rounded-lg border ${className}`}
    >
      <div
        className={`w-6 h-6 rounded-full flex items-center justify-center flex-shrink-0 text-xs font-medium ${avatarClass}`}
      >
        {letter}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-2 mb-1">
          <span className="font-medium text-xs text-gray-700">{label}</span>
          {message.timestamp && (
            <span className="text-[10px] text-gray-400">
              {formatTimestamp(message.timestamp)}
            </span>
          )}
        </div>
        {message.thinking && (
          <ThinkingBlock thinking={message.thinking} isPartial={false} />
        )}
        <MessageContent
          parts={
            message.role === "user"
              ? [
                  {
                    kind: "text",
                    text: stripModePrefix(message.content || "", message.mode),
                  },
                ]
              : message.parts
          }
          isPartial={false}
          className="text-xs text-gray-700"
        />
        {message.toolCalls && message.toolCalls.length > 0 && (
          <div className="mt-2 text-[11px] text-gray-500">
            {message.toolCalls.length} tool call
            {message.toolCalls.length === 1 ? "" : "s"}
          </div>
        )}
        {message.toolResults && message.toolResults.length > 0 && (
          <div className="mt-1 text-[11px] text-gray-500">
            {message.toolResults.length} tool result
            {message.toolResults.length === 1 ? "" : "s"}
          </div>
        )}
      </div>
    </div>
  );
}

// The marker box rendered at the end of the visible list.
// Carries the archived count + token stats. The full LLM
// summary is intentionally NOT shown here — it's already
// represented in the active messages list as a user-encoded
// "Summary of earlier conversation:\n\n<text>" message, so
// the marker box stays focused on the boundary stats.
function CompactionMarkerBox({ marker }) {
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

// Walk backwards and pick the LAST compaction entry's index.
// Earlier markers are filtered out (their boundaries aren't
// visible at this zoom level — the parent's divider handles
// the most recent one).
function findLastCompactionIndex(history) {
  for (let i = history.length - 1; i >= 0; i--) {
    if (history[i]?.role === "compaction") return i;
  }
  return -1;
}

export function CollapsedHistory({ history }) {
  if (!history || history.length === 0) {
    return null;
  }

  const lastCompactionIdx = findLastCompactionIndex(history);

  // Non-compaction messages keep their original order. The
  // marker is rendered AFTER them as the visual "this is the
  // boundary" indicator — the last item in the visible list,
  // regardless of its index in the wire-format history.
  const messages = history.filter((m) => m?.role && m.role !== "compaction");
  const lastMarker = lastCompactionIdx >= 0 ? history[lastCompactionIdx] : null;

  // `messages.length === 0` happens only when every entry is a
  // compaction marker. By construction that means `lastMarker`
  // is non-null (there's at least one compaction), so the
  // "no archived messages" placeholder is unreachable here.
  // The guard stays as a structural pin for future shape changes.
  if (messages.length === 0 && !lastMarker) {
    return (
      <div className="text-[11px] text-gray-400 italic px-2 py-1">
        No archived messages to display.
      </div>
    );
  }

  return (
    <div
      data-testid="collapsed-history"
      className="space-y-2 max-h-96 overflow-y-auto p-2 bg-amber-50/30 rounded-md border border-amber-200/40"
    >
      {messages.map((m, i) => (
        <MessageBubble key={m.index ?? i} message={m} />
      ))}
      {lastMarker && (
        <CompactionMarkerBox
          key={lastMarker.index ?? "marker"}
          marker={lastMarker}
        />
      )}
    </div>
  );
}
