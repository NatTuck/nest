/**
 * The wire's `commandOutputParts` marker: which of a message's `parts` are a
 * backgrounded shell command's own output rather than prose (issue #139).
 *
 * It is its own module because three callers need the same validated answer —
 * `messageParts.js` (to render the output as output), `formatMessage.js` (to
 * copy it byte for byte) and `header.js` (to keep a command's bytes out of the
 * sender walk, since output is a body's tail and its first line can look like
 * wire framing).
 *
 * The value decides how text is rendered, so a malformed one is a server bug
 * that has to be loud rather than silently ignored — this project does not hide
 * what it cannot render (AGENTS.md, "UI Transparency"). Anything other than an
 * array of non-negative integers, or an index that is not a `text` part,
 * throws naming the offending value. `null` is not "absent": the wire contract
 * omits the key when there is no command output, so a `null` is a disagreement
 * with it and is reported like any other wrong value.
 */
export function commandOutputIndexes(message, parts) {
  const raw = message?.commandOutputParts;
  if (raw === undefined) return new Set();

  if (!Array.isArray(raw)) {
    throw new Error(
      `commandOutputParts must be an array of parts indexes, got ${JSON.stringify(raw)}`,
    );
  }

  const indexes = new Set();
  for (const value of raw) {
    if (!Number.isInteger(value) || value < 0) {
      throw new Error(
        `commandOutputParts must name non-negative integer indexes into parts, got ${JSON.stringify(value)}`,
      );
    }

    const part = parts[value];
    if (!part || part.kind !== "text") {
      // Name what was found rather than the whole part: a `media` part carries
      // its base64 payload, which does not belong in an error message.
      const found = part
        ? `a part whose kind is ${JSON.stringify(part.kind ?? null)}`
        : `no part at all (parts has ${parts.length} entries)`;
      throw new Error(
        `commandOutputParts names parts[${value}], which is not a text part: found ${found}`,
      );
    }

    indexes.add(value);
  }

  return indexes;
}
