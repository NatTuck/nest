/**
 * The `[From … | mode: <mode>]` header on a user-role row: what the server
 * writes, and removing it for display.
 *
 * Every user-role row states who is speaking and the recipient's mode:
 *
 *     [From user | mode: act]
 *     [From user @nat | mode: act]
 *     [From agent crazy-dolphin | mode: plan]
 *     [From nest runtime | mode: act]
 *
 * ...with `, agents-send reply required` after the sender when the note
 * obliges an answer, and `mode: compact` on the runtime's compaction request.
 * The chat UI already renders the mode as the row's badge, and the sender is
 * the row's own author, so the header is wire framing — it is removed at
 * render time, exactly as the markers it replaced were.
 *
 * **A header heads a body, not the message.** A drained batch is one user row
 * holding several entries, so each entry's body carries its own header and the
 * batch row has no outer one. A header is therefore removed when it is the
 * whole of a line and that line is the first of the content or follows a blank
 * line. Anywhere else — mid line, or mid body — it is text someone wrote, and
 * it stays.
 *
 * ## Rows recorded before the header
 *
 * Transcripts persisted before this change carry the markers the header
 * replaced, and they must not start showing wire framing. Two of them are
 * whole lines, so they are removed here: the old `[mode: <mode>]` prefix at the
 * head of the content, and the old `[nest notice]` marker at the head of any
 * body. The third — the old `[Message from agent "…"]` label — wraps a body
 * rather than heading one, and is handled by `agentHeader.js`.
 *
 * ## The mode guard
 *
 * `mode` is untrusted, so a header (or an old `[mode: X]` prefix) is removed
 * only when its mode clause agrees with the message's own `mode` field. A
 * disagreement — a bug, or a row written by a build with a different idea of
 * the mode — keeps its text and stays visible rather than being hidden. The
 * retired notice marker has no mode to check against, so the marker itself is
 * the whole signal, exactly as it was when it was produced.
 */

// The header's opening. The server's copy of the format lives in
// `Nest.Messages.Header`; the duplication is deliberate — the browser bundle
// cannot read Elixir — and the two are kept in step by the header tests on each
// side.
const HEADER_OPEN = "[From ";

// The old agent label's opening, kept for `agentHeader.js`'s legacy clause
// stripper so the wire strings have one home.
export const AGENT_LABEL_OPEN = "[Message from agent";

// The retired notice marker, without the trailing newline. Only rows recorded
// before the header carry it.
export const NOTICE_TAG = "[nest notice]";

// The retired mode prefix's opening, without the mode or the closing bracket.
const MODE_PREFIX_OPEN = "[mode: ";

export function stripHeader(content, mode) {
  if (typeof content !== "string") return content;

  const kept = [];
  for (const line of content.split("\n")) {
    if (droppable(line, kept, mode)) continue;
    kept.push(line);
  }
  return kept.join("\n");
}

function droppable(line, kept, mode) {
  // The retired marker: no mode to check it against, so a whole line at a body
  // head is the whole signal.
  if (line === NOTICE_TAG) return headsABody(kept);

  if (!hasMode(mode)) return false;

  // The retired prefix was only ever written at the head of the content.
  if (line === `${MODE_PREFIX_OPEN}${mode}]`) return kept.length === 0;

  return headsABody(kept) && headerMode(line) === mode;
}

function hasMode(mode) {
  return typeof mode === "string" && mode !== "";
}

// `[From … | mode: <mode>]` → the mode, or `null` when the line is not a
// header. A header without a mode clause is not one this build writes, so it is
// not one it removes.
function headerMode(line) {
  if (!line.startsWith(HEADER_OPEN) || !line.endsWith("]")) return null;
  const match = line.match(/ \| mode: (.+)\]$/);
  return match ? match[1] : null;
}

// Whether the line about to be examined starts a body: it is the first line of
// the content, or it follows a blank line.
function headsABody(kept) {
  if (kept.length === 0) return true;
  return kept[kept.length - 1] === "";
}
