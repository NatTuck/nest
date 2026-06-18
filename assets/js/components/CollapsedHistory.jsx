/**
 * CollapsedHistory — renders the archived messages that were
 * moved to the agent's `history` field by compaction.
 *
 * Renders read-only message bubbles (no edit / re-send), with a
 * muted style that signals "this is older context, not part of
 * the current conversation." Compaction markers (`role: "compaction"`)
 * are skipped — they're already represented by the `CompactionMarker`
 * parent in the visible timeline.
 *
 * Long message content is rendered as-is (no truncation here).
 * Tool calls and tool results are surfaced so the reader can see
 * what the agent did before compaction.
 */

import { MessageContent } from "./MessageContent";

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
  try {
    return new Date(ts).toLocaleString();
  } catch {
    return ts;
  }
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
        <MessageContent
          content={message.content}
          segments={message.segments}
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

export function CollapsedHistory({ history }) {
  if (!history || history.length === 0) {
    return null;
  }

  const visible = history.filter((m) => m?.role && m.role !== "compaction");

  if (visible.length === 0) {
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
      {visible.map((m, i) => (
        <MessageBubble key={m.index ?? i} message={m} />
      ))}
    </div>
  );
}
