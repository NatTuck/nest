/**
 * The `[Message from agent "NAME" | mode: <mode>]` header: the clause the
 * server adds to it, and removing it for display.
 *
 * Every message an agent receives states **the recipient's** mode: a user
 * message as a `[mode: <mode>]\n` prefix (`utils/stripModePrefix.js`), and a
 * peer delivery in the header of the body it wraps. That is the only mechanism
 * by which an agent whose inbox is all peer traffic learns its own mode — the
 * mode is a per-agent runtime property (`Nest.Modes`) and nothing else in a
 * peer's message carries it.
 *
 * The chat UI already renders the same value as the row's mode badge, so the
 * header's copy is a duplicate on screen. `stripAgentHeaderMode` removes it,
 * exactly as `stripModePrefix` removes the prefix the badge also shows.
 *
 * The guard is the same one `stripModePrefix` uses, and for the same reason:
 * `mode` is untrusted. Only the clause that *agrees* with the message's own
 * `mode` is removed, so a header that disagrees — a bug, or a row written by an
 * older build — keeps its text and the disagreement stays visible rather than
 * being hidden.
 */

// The header's opening. A peer delivery is labelled with this; a human's own
// message (`[Message from the user "…"]`) and a runtime notice carry different
// markers and are left alone.
const AGENT_HEADER_PREFIX = "[Message from agent";

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
