/**
 * The retired `[Message from agent "NAME" | mode: <mode>]` label: the mode
 * clause it carried, and removing that clause for display.
 *
 * **Legacy only.** The label was replaced by the `[From … | mode: …]` header
 * (`utils/stripHeader.js`), which is a whole line rather than a wrapper around
 * a body, so nothing writes this shape any more. Transcripts recorded before
 * the header still carry it, and there the label is the only thing that says
 * who spoke — so the label itself stays on screen and only its ` | mode: X`
 * clause goes, because the row's badge already shows the mode.
 *
 * The guard is the one `stripHeader` uses, and for the same reason: `mode` is
 * untrusted. Only the clause that *agrees* with the message's own `mode` is
 * removed, so a label that disagrees — a bug, or a row written by an older
 * build — keeps its text and the disagreement stays visible rather than being
 * hidden.
 */

import { AGENT_LABEL_OPEN } from "./stripHeader.js";

// The label's opening. A human's own message and a runtime notice never carried
// it, so they are left alone.
const AGENT_HEADER_PREFIX = AGENT_LABEL_OPEN;

/**
 * Remove the ` | mode: <mode>` clause from an agent message's header line.
 *
 * Returns `content` unchanged when there is no header, when the clause is
 * absent (every row persisted before the header carried a mode), or when the
 * clause names a different mode than the message's `mode` field.
 */
export function stripAgentHeaderMode(content, mode) {
  if (typeof content !== "string") return content;
  if (typeof mode !== "string" || mode === "") return content;
  if (!content.includes(AGENT_HEADER_PREFIX)) return content;

  const clause = ` | mode: ${mode}]`;

  return content
    .split("\n")
    .map((line) =>
      line.startsWith(AGENT_HEADER_PREFIX) && line.endsWith(clause)
        ? `${line.slice(0, line.length - clause.length)}]`
        : line,
    )
    .join("\n");
}

/**
 * The header's mode, or `null` when the text has no header or no mode in it.
 *
 * Used by the tests and by anything that wants to check the header's own claim
 * against the message's `mode` field rather than trusting one of them.
 */
export function agentHeaderMode(content) {
  if (typeof content !== "string") return null;

  for (const line of content.split("\n")) {
    if (!line.startsWith(AGENT_HEADER_PREFIX)) continue;
    const match = line.match(/ \| mode: (.+)\]$/);
    return match ? match[1] : null;
  }

  return null;
}
