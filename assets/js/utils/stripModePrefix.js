/**
 * Strips the `[mode: <name>]\n` prefix from a user message's
 * `content` field.
 *
 * The server-side chat pipeline intentionally prefixes every
 * persisted user message with the effective mode, so the LLM sees
 * the mode as part of the message text (and so the prefix
 * round-trips through any persistence / replay layer). The chat UI
 * doesn't want to show that prefix on screen because the mode
 * badge already displays it.
 *
 * This function returns the content with the prefix removed when
 * the prefix matches the message's `mode` field. If the content
 * does not start with that exact prefix, the content is returned
 * unchanged — this is the safe default for:
 *
 *   * legacy messages (or fixtures) that don't have the prefix
 *   * messages broadcast before a hypothetical server downgrade
 *   * any malformed payload where `mode` and the prefix disagree
 *
 * The `mode` parameter is treated as untrusted: if it is empty /
 * missing, the prefix is never stripped, even if the content
 * happens to start with `[mode: chat]\n`. This prevents an empty
 * `mode` from accidentally stripping any leading `[mode: X]\n`
 * text that a user typed into their message.
 */
export function stripModePrefix(content, mode) {
  if (typeof content !== "string") return content;
  if (typeof mode !== "string" || mode === "") return content;
  const prefix = `[mode: ${mode}]\n`;
  if (content.startsWith(prefix)) {
    return content.slice(prefix.length);
  }
  return content;
}
