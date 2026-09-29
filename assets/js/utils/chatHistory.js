/**
 * Build the chat-input history list (Ctrl/Cmd+Up / Down navigation).
 *
 * Pulls user messages from both the active session and the archived
 * (post-compaction) history, orders them most-recent-first, and collapses
 * consecutive duplicates so repeated presses of Up don't dwell on the same
 * message. Archived rows arrive in the wire format (`parts`, no flat
 * `content`), so the text is extracted via `messageText` (which prefers
 * `parts` and falls back to a legacy `content` string). The persisted
 * content has a `[mode: <name>]\n` prefix, which is stripped here so the
 * recovered prompt is the user-visible text.
 */

import { messageText } from "./messageText.js";
import { stripModePrefix } from "./stripModePrefix.js";

function toHistoryEntry(message) {
  if (message?.role !== "user") return null;

  const raw =
    typeof message.content === "string"
      ? message.content
      : messageText(message);
  if (!raw) return null;

  return {
    content: stripModePrefix(raw, message.mode ?? ""),
    mode: message.mode ?? null,
  };
}

export function buildChatHistory(messages, archivedHistory) {
  const archived = (archivedHistory || []).map(toHistoryEntry).filter(Boolean);
  const active = (messages || []).map(toHistoryEntry).filter(Boolean);
  const ordered = [...archived, ...active];
  const deduped = [];
  for (const entry of ordered) {
    const last = deduped[deduped.length - 1];
    if (!last || last.content !== entry.content) deduped.push(entry);
  }
  return deduped.reverse();
}
