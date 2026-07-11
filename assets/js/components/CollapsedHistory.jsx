/**
 * CollapsedHistory — renders the archived message sequence an
 * agent moved to its `history` field via compaction.
 *
 * Renders the FULL sequence (`history ++ messages` in the agent's
 * in-memory partition, or `cache.history` on the client) in
 * original index order, with every message type rendered through
 * the same components the active message list uses:
 * `SystemMessageContent` (with line-count truncation) for
 * system messages, `MessageContent` + `ThinkingBlock` +
 * `ToolCalls` for assistant messages, `ToolResults` for tool
 * messages, and `ApiLogsBlock` for any message with API logs.
 * Compaction markers render inline via `CompactionMarkerBox`,
 * one per `role: "compaction"` entry, so the user can see every
 * boundary and read per-compaction stats. Earlier markers are no
 * longer filtered out.
 *
 * Long message content is rendered as-is (no truncation here
 * other than what `SystemMessageContent` does for system
 * messages). Tool calls and tool results are surfaced so the
 * reader can see what the agent did before compaction.
 */

import { MessageContent } from "./MessageContent.jsx";
import { ThinkingBlock } from "./ThinkingBlock.jsx";
import { ToolCalls } from "./ToolCalls.jsx";
import { ToolResults } from "./ToolResults.jsx";
import { ApiLogsBlock } from "./ApiLogsBlock.jsx";
import { SystemMessageContent } from "./SystemMessageContent.jsx";
import { CompactionMarkerBox } from "./CompactionMarker.jsx";
import { stripModePrefix } from "../utils/stripModePrefix.js";
import { textFromParts } from "../utils/messageText.js";
import { splitThinkFromParts } from "../utils/thinkTags.js";

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

// Concatenate the thinking content for an assistant message:
// both `Part.Thinking` entries AND any `<think>...</think>`
// blocks buried in `Part.Text` text. Mirrors the live-area
// `thinkingFor` helper in ChatPage.jsx so the history pane
// renders an identical ThinkingBlock.
function thinkingFor(message) {
  return splitThinkFromParts(message?.parts).thinking;
}

// Extract the text parts for an assistant message, with any
// `<think>...</think>` blocks removed (their content was
// routed into the ThinkingBlock above). Mirrors the
// live-area derivation in `addChatMessage` so a re-broadcast
// assistant message renders the same in the history pane.
function textPartsFor(message) {
  return splitThinkFromParts(message?.parts).textParts;
}

// Derive the legacy `toolCalls` shape from a message's `parts`
// (the wire format). Returns `null` when no `tool_use` parts
// are present, mirroring the live-area derivation in
// `addChatMessage` so a re-broadcast tool-call message renders
// the same in the history pane.
function toolCallsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const tcs = parts.filter((p) => p && p.kind === "tool_use");
  if (tcs.length === 0) return null;
  return tcs.map((p) => ({
    id: p.id,
    name: p.name,
    arguments: p.arguments || {},
  }));
}

// Derive the legacy `toolResults` shape from a message's `parts`.
function toolResultsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const trs = parts.filter((p) => p && p.kind === "tool_result");
  if (trs.length === 0) return null;
  return trs.map((p) => ({
    tool_call_id: p.toolCallId,
    name: p.name,
    content: p.content || "",
    is_error: !!p.isError,
  }));
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
        {role === "system" ? (
          <SystemMessageContent parts={message.parts} isPartial={false} />
        ) : role === "user" ? (
          <MessageContent
            parts={[
              {
                kind: "text",
                text: stripModePrefix(
                  textFromParts(message.parts),
                  message.mode,
                ),
              },
            ]}
            isPartial={false}
            className="text-xs text-gray-700"
          />
        ) : (
          <>
            <ThinkingBlock thinking={thinkingFor(message)} isPartial={false} />
            <MessageContent
              parts={textPartsFor(message)}
              isPartial={false}
              className="text-xs text-gray-700"
            />
            <ToolCalls toolCalls={toolCallsFromParts(message.parts)} />
            <ToolResults toolResults={toolResultsFromParts(message.parts)} />
            <ApiLogsBlock apiLogs={message.apiLogs} />
          </>
        )}
      </div>
    </div>
  );
}

export function CollapsedHistory({ history }) {
  if (!history || history.length === 0) {
    return null;
  }

  // Render the full sequence in original index order. Each
  // entry is either a regular message (system / user /
  // assistant / tool) or a `{:compaction, _}` marker; markers
  // are rendered inline as `CompactionMarkerBox` so the user
  // sees every boundary, not just the most recent one.
  return (
    <div
      data-testid="collapsed-history"
      className="space-y-2 max-h-96 overflow-y-auto p-2 bg-amber-50/30 rounded-md border border-amber-200/40"
    >
      {history.map((m, i) =>
        m?.role === "compaction" ? (
          <CompactionMarkerBox key={m.index ?? `marker-${i}`} marker={m} />
        ) : (
          <MessageBubble key={m.index ?? i} message={m} />
        ),
      )}
    </div>
  );
}
