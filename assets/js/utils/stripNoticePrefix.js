/**
 * Strips the `[nest notice]\n` prefix from a runtime notice's `content`.
 *
 * The server-side builders put the marker at the head of every synthetic
 * runtime notice's text — a context or budget reminder, a backgrounded
 * batch's outcome, a stop cancellation, a lost promise — so the LLM can tell
 * the runtime's own words from a human's or a peer's (see
 * `Nest.Agents.Agent.NoticeTag`). The chat UI doesn't want to show that
 * marker: the bubble's role/attention already says what the row is, and the
 * marker is wire framing, not something anyone wrote.
 *
 * This mirrors `stripModePrefix`: the notice tag is a wire-level marker
 * exactly like `[mode: <name>]`, applied by the server and removed at render
 * time. The two differ in the guard they can use. A `[mode: X]` prefix is
 * stripped only when it agrees with the message's `mode` field, so a user
 * who typed one is safe; a notice row carries no such second field, so the
 * marker itself is the whole signal and a leading `[nest notice]\n` is always
 * removed.
 *
 * The function is a leading-prefix removal, nothing more: the server only
 * ever puts the tag at the head of a row's text, never mid-text (the fused
 * `assistant(notice + ack)` row included), which is what keeps this simple.
 * A non-string input, or one without the prefix, is returned unchanged.
 */

// The marker itself, without the trailing newline. The server's copy of this
// string lives in `Nest.Agents.Agent.NoticeTag`; the duplication is
// deliberate — the browser bundle cannot read Elixir — and the two are kept
// in step by the notice tests on each side.
export const NOTICE_TAG = "[nest notice]";

export function stripNoticePrefix(content) {
  if (typeof content !== "string") return content;
  const prefix = `${NOTICE_TAG}\n`;
  if (content.startsWith(prefix)) {
    return content.slice(prefix.length);
  }
  return content;
}
