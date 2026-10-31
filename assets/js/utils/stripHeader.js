/**
 * Removing the wire framing from a row's text, for display and for the
 * clipboard.
 *
 * ## What goes, and why
 *
 * The framing is the `[From … | mode: …]` header on every body
 * (`utils/header.js` has the grammar), plus the markers it replaced: the
 * `[mode: <mode>]` prefix and the `[nest notice]` marker. The third old marker,
 * `[Message from agent "…"]`, wraps a body rather than heading one and is
 * handled by `agentHeader.js`.
 *
 * A line is removed only after `header.js`'s parse has read it, and only when
 * the mode it names agrees with the message's own `mode`. That guard is the
 * same one the badge uses: `mode` is untrusted, so a header that disagrees — a
 * bug, or a row written by a build with a different idea of the mode — keeps
 * its text and stays visible rather than being hidden.
 *
 * `splitFraming` returns the parsed headers **alongside** the text, so a caller
 * cannot delete a header without holding the facts it carried: the row label
 * and the per-body captions are built from the same parse that decided the
 * removal (`utils/messageParts.js`'s `userPartsFor`).
 *
 * ## The two removals
 *
 * A header line goes only from the display. The clipboard keeps it: plain text
 * has no badge, so by the rule above the sender is content there. The retired
 * markers have no affordance on either surface, so `stripRetiredMarkers` is
 * what the clipboard uses.
 *
 * **A header heads a body, not the message.** A drained batch is one user row
 * holding several entries, so each entry's body carries its own header and the
 * batch row has no outer one. A header is therefore removed when it is the
 * whole of a line and that line is the first of the content or follows a blank
 * line. Anywhere else — mid line, or mid body — it is text someone wrote, and
 * it stays.
 */

import { NOTICE_TAG, parseHeaderLine } from "./header.js";

// The wire strings live in `header.js`, with the rest of the grammar.
// Re-exported here so `agentHeader.js` (and the tests) keep importing them from
// the module that removes the framing.
export { AGENT_LABEL_OPEN, NOTICE_TAG } from "./header.js";

// The retired mode prefix's opening, without the mode or the closing bracket.
const MODE_PREFIX_OPEN = "[mode: ";

/**
 * `content` split into the text to show and the headers that were removed.
 *
 * Returns `{text, headers}`: `headers` are the parsed `[From …]` headers whose
 * lines were dropped, in order, so the caller has the sender, the reply marker
 * and the mode of every body it is about to render.
 */
export function splitFraming(content, mode) {
  return split(content, mode, true);
}

/**
 * `content` with only the retired markers removed — the `[mode: <mode>]` prefix
 * and the `[nest notice]` marker. The header lines stay: the clipboard is plain
 * text, so the sender has no other home there.
 */
export function stripRetiredMarkers(content, mode) {
  return split(content, mode, false).text;
}

// One walk, one parse. `dropHeaders` is the only difference between the two
// callers: the display removes a header because it renders the sender as an
// affordance, and the clipboard keeps it because there is no affordance to
// carry it.
function split(content, mode, dropHeaders) {
  if (typeof content !== "string") return { text: content, headers: [] };

  const kept = [];
  const headers = [];
  let atBodyHead = true;

  for (const line of content.split("\n")) {
    const header = parseHeaderLine(line);

    if (
      header &&
      dropHeaders &&
      hasMode(mode) &&
      header.mode === mode &&
      atBodyHead
    ) {
      headers.push(header);
      // A header heads the body that follows it, so the next line is still that
      // body's first.
      continue;
    }

    if (droppableMarker(line, atBodyHead, kept, mode)) continue;

    kept.push(line);
    // A blank line starts a new body, and so does a header line — kept here for
    // the clipboard, or because its mode disagrees. Everything else is the
    // middle of a body.
    atBodyHead = line === "" || !!header;
  }

  return { text: kept.join("\n"), headers };
}

function droppableMarker(line, atBodyHead, kept, mode) {
  // The retired marker: no mode to check it against, so a whole line at a body
  // head is the whole signal.
  if (line === NOTICE_TAG) return atBodyHead;

  if (!hasMode(mode)) return false;

  // The retired prefix was only ever written at the head of the content.
  if (line === `${MODE_PREFIX_OPEN}${mode}]`) return kept.length === 0;

  return false;
}

function hasMode(mode) {
  return typeof mode === "string" && mode !== "";
}
