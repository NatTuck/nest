/**
 * SystemMessageContent — renders a system message with line-count
 * truncation. If the content exceeds SYSTEM_MESSAGE_MAX_LINES, only
 * the first N lines are shown with an "Expand N more lines" toggle.
 *
 * An empty system message (no system prompt was configured for this
 * agent) is still rendered as a dimmed placeholder — so the user can
 * see that a system message was sent to the LLM (the AGENTS.md
 * transparency rule: the UI always includes everything that
 * happened). Without this, an agent with no system prompt would
 * have no visible representation of position 0 in the messages
 * list, and the conversation history would be confusing.
 */
import { useState } from "react";
import { MessageContent } from "./MessageContent.jsx";

const SYSTEM_MESSAGE_MAX_LINES = 20;

export function SystemMessageContent({ parts, isPartial }) {
  const [expanded, setExpanded] = useState(false);

  const text = Array.isArray(parts)
    ? parts
        .filter((p) => p && p.kind === "text")
        .map((p) => p.text || "")
        .join("")
    : "";

  if (!text) {
    return (
      <div className="text-sm italic text-gray-400 border-l-2 border-gray-200 pl-2">
        (empty system message — no system prompt was configured for this agent)
      </div>
    );
  }

  if (isPartial) {
    return (
      <MessageContent
        parts={[{ kind: "text", text }]}
        isPartial
        className="text-gray-800"
      />
    );
  }

  const lines = text.split("\n");
  const showExpand = lines.length > SYSTEM_MESSAGE_MAX_LINES;
  const visibleLines = expanded
    ? lines
    : lines.slice(0, SYSTEM_MESSAGE_MAX_LINES);
  const hiddenCount = lines.length - SYSTEM_MESSAGE_MAX_LINES;

  return (
    <div>
      <MessageContent
        parts={[{ kind: "text", text: visibleLines.join("\n") }]}
        className="text-gray-800"
      />
      {showExpand && (
        <button
          type="button"
          onClick={() => setExpanded(!expanded)}
          className="mt-2 text-sm text-blue-600 hover:text-blue-800 underline"
        >
          {expanded
            ? "Show less"
            : `Expand ${hiddenCount} more line${hiddenCount !== 1 ? "s" : ""}`}
        </button>
      )}
    </div>
  );
}
