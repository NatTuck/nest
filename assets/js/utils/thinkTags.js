/**
 * The legacy `<think>…</think>` reasoning marker, and the one shape of it this
 * build still reads.
 *
 * ## The rule
 *
 * A marker is wire framing **only when the fact it carries has a home
 * elsewhere in the row**. The server emits at most one `Part.Thinking` and puts
 * it first (`Nest.Agents.Agent.Turn.Messages.build_assistant_parts/1`, with the
 * comment that Anthropic requires the thinking block to lead), so a row that
 * carries one has already stated its reasoning — its text is prose and is never
 * scanned. The only other home is the shape this build still has to read: an
 * **assistant** row whose **first** text part opens with a matched
 * `<think>…</think>` block, written by a build that had no `Part.Thinking`.
 *
 * Everything else is prose. A `<think>` in the middle of a sentence, an
 * unclosed `<think>`, and a stray `</think>` all stay exactly where they are.
 * That is the regression this module exists to prevent: the old splitter
 * treated an orphan `<think>` as "everything to the end of the string is
 * reasoning", so an assistant message that merely *discussed* the tag lost the
 * rest of its text.
 *
 * So this module exports one function, and it never looks past the head of the
 * string. Which part of a *message* that block belongs to is
 * `messageParts.js`'s `splitReasoning/1`.
 */

const THINK_OPEN = "<think>";
const THINK_CLOSE = "</think>";

/**
 * The leading `<think>…</think>` block of `text`, or `null` when `text` does
 * not start with one.
 *
 * Returns `{thinking, rest}`: the block's content (without the markers) and
 * everything after the **first** `</think>`. Nesting is not supported — the
 * block ends at the first closer, so a nested opener is content, which is the
 * honest reading of a marker nothing writes any more.
 *
 * `null` for a non-string, for text that does not start with `<think>`, and for
 * a leading `<think>` with no `</think>` after it.
 */
export function leadingThinkBlock(text) {
  if (typeof text !== "string" || !text.startsWith(THINK_OPEN)) return null;

  const end = text.indexOf(THINK_CLOSE, THINK_OPEN.length);
  if (end === -1) return null;

  return {
    thinking: text.slice(THINK_OPEN.length, end),
    rest: text.slice(end + THINK_CLOSE.length),
  };
}
