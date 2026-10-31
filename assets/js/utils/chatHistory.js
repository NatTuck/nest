/**
 * Build the chat-input history list (Ctrl/Cmd+Up / Down navigation).
 *
 * Only messages the human actually typed are eligible: a user-role row is
 * included **iff** it carries `origin: "human"` **and** `composed: true`
 * (stamped by the server — see `Nest.Messages.User.source_metadata/1`). The
 * user role is overloaded on the wire: peer deliveries
 * (`[Message from agent "X"] …`), runtime notices and synthetic reminders are
 * all persisted as user rows, and none of them is a prompt the human typed.
 * `origin` alone is not enough — it marks the human's *words*, and the UI
 * produces some of those itself (a decision answer, an explain request), so
 * those rows are `origin: "human"` without `composed`. The rule is
 * fail-closed, so anything unmarked is excluded.
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
 * hand back what the bubble showed. Each entry is `{content}` and nothing else:
 * the mode is an input to the stripping, not a fact the list carries.
 */

import { messageText } from "./messageText.js";
import { splitFraming } from "./stripHeader.js";

// The `metadata.origin` value the server stamps on the human's own message.
const HUMAN_ORIGIN = "human";

function toHistoryEntry(message) {
  if (message?.role !== "user") return null;
  // Two markers, because `origin` alone is not the same thing. It marks the
  // human's *words*, and the UI produces some of those itself — a decision
  // answer, an explain request — so it is also stamped on rows nobody typed.
  // `composed` is the composer's own: it is what makes a prompt recallable.
  //
  // Fail-closed, like every other filter here: an untagged user row (peer
  // delivery, notice, runtime reminder, or a row persisted before either marker
  // existed) is not a prompt the human typed.
  if (message.origin !== HUMAN_ORIGIN || message.composed !== true) return null;

  const raw =
    typeof message.content === "string"
      ? message.content
      : messageText(message);
  if (!raw) return null;

  // `mode` is read here and only here: it is what `splitFraming` needs to take
  // the `[mode: X]\n` prefix off, so the recalled text is what the bubble
  // showed. It does not ride the entry — walking the history changes the text
  // and nothing else, so a mode on the entry would be data no consumer reads.
  //
  // The `[From …]` header is stripped too, and that is justified here in a way
  // it is not for the clipboard: this list is filtered to `origin: "human"` &&
  // `composed`, so the sender is provably the human themself and the recalled
  // text is what they typed.
  return { content: splitFraming(raw, message.mode ?? "").text };
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
