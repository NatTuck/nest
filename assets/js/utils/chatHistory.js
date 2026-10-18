/**
 * Build the chat-input history list (Ctrl/Cmd+Up / Down navigation).
 *
 * Only messages the human actually typed are eligible: a user-role row is
 * included **iff** it carries `origin: "human"` (stamped by the server — see
 * `Nest.Messages.User.human_metadata/0`). The user role is overloaded on the
 * wire: peer deliveries (`[Message from agent "X"] …`), runtime notices and
 * synthetic reminders are all persisted as user rows, and none of them is a
 * prompt the human typed. The rule is fail-closed, so anything unmarked is
 * excluded.
 *
 * Consequence: rows persisted before the marker existed are untagged and
 * therefore leave the recall list. Nothing is deleted — the transcript is
 * untouched — so relaxing this rule restores them.
 *
 * Pulls those messages from both the active session and the archived
 * (post-compaction) history, orders them most-recent-first, and collapses
 * consecutive duplicates so repeated presses of Up don't dwell on the same
 * message. Archived rows arrive in the wire format (`parts`, no flat
 * `content`), so the text is extracted via `messageText` (which prefers
 * `parts` and falls back to a legacy `content` string). The persisted
 * content has a `[mode: <name>]\n` prefix, which is stripped here so the
 * recovered prompt is the user-visible text, and a `[nest notice]\n` marker is
 * stripped the same way — the bubble strips both, and the recall list must
 * hand back what the bubble showed.
 */

import { messageText } from "./messageText.js";
import { stripHeader } from "./stripHeader.js";

// The `metadata.origin` value the server stamps on the human's own message.
const HUMAN_ORIGIN = "human";

function toHistoryEntry(message) {
  if (message?.role !== "user") return null;
  // Fail-closed: an untagged user row (peer delivery, notice, runtime
  // reminder, or a pre-marker row) is not a prompt the human typed.
  if (message.origin !== HUMAN_ORIGIN) return null;

  const raw =
    typeof message.content === "string"
      ? message.content
      : messageText(message);
  if (!raw) return null;

  return {
    content: stripHeader(raw, message.mode ?? ""),
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
