/**
 * Build the chat-input history list (Ctrl/Cmd+Up / Down navigation).
 *
 * Pulls user messages from both the active session and the archived
 * (post-compaction) history, orders them most-recent-first, and collapses
 * consecutive duplicates so repeated presses of Up don't dwell on the same
 * message. The persisted content has a `[mode: <name>]\n` prefix, which is
 * stripped here so the recovered prompt is the user-visible text.
 */

import { stripModePrefix } from "./stripModePrefix.js";

export function buildChatHistory(messages, archivedHistory) {
  const archived = (archivedHistory || [])
    .filter((m) => m.role === "user" && typeof m.content === "string")
    .map((m) => ({
      content: stripModePrefix(m.content, m.mode ?? ""),
      mode: m.mode ?? null,
    }));
  const active = (messages || [])
    .filter((m) => m.role === "user" && typeof m.content === "string")
    .map((m) => ({
      content: stripModePrefix(m.content, m.mode ?? ""),
      mode: m.mode ?? null,
    }));
  const ordered = [...archived, ...active];
  const deduped = [];
  for (const entry of ordered) {
    const last = deduped[deduped.length - 1];
    if (!last || last.content !== entry.content) deduped.push(entry);
  }
  return deduped.reverse();
}
