/**
 * Strips the `[nest notice]\n` marker from a runtime notice's `content`.
 *
 * The server-side builders put the marker at the head of every synthetic
 * runtime notice's text — a context or budget reminder, a backgrounded
 * batch's outcome, a stop cancellation, a lost promise, a reply obligation, a
 * re-prompt nudge, a workspace change (see `Nest.Messages.NoticeTag`) — so the
 * LLM can tell the runtime's own words from a human's or a peer's. The chat UI
 * doesn't want to show that marker: the bubble's role/attention already says
 * what the row is, and the marker is wire framing, not something anyone wrote.
 *
 * This mirrors `stripModePrefix`: the notice marker is a wire-level marker
 * exactly like `[mode: <name>]`, applied by the server and removed at render
 * time. The two differ in the guard they can use. A `[mode: X]` prefix is
 * stripped only when it agrees with the message's `mode` field, so a user who
 * typed one is safe; a notice row carries no such second field, so the marker
 * itself is the whole signal.
 *
 * **A marker heads a body, not the message.** `Inbox.Render` joins a drain
 * batch's entries with a blank line, so a notice behind a peer's entry puts
 * the marker at the head of the *second* body. So a marker is removed when it
 * is the whole of a line and that line is the first of the content or follows
 * a blank line. Anywhere else — mid line, or mid body — it is text someone
 * wrote, and it stays.
 */

// The marker itself, without the trailing newline. The server's copy of this
// string lives in `Nest.Messages.NoticeTag`; the duplication is deliberate —
// the browser bundle cannot read Elixir — and the two are kept in step by the
// notice tests on each side.
export const NOTICE_TAG = "[nest notice]";

export function stripNoticePrefix(content) {
  if (typeof content !== "string") return content;
  if (!content.includes(NOTICE_TAG)) return content;

  const kept = [];
  for (const line of content.split("\n")) {
    if (line === NOTICE_TAG && headsABody(kept)) continue;
    kept.push(line);
  }
  return kept.join("\n");
}

// Whether the line about to be examined starts a body: it is the first line of
// the content, or it follows a blank line.
function headsABody(kept) {
  if (kept.length === 0) return true;
  return kept[kept.length - 1] === "";
}
