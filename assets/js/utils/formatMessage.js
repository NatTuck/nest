/**
 * Convert chat messages and API log arrays to plain-text representations
 * suitable for clipboard copy.
 *
 *   - `messageToMarkdown(message)` produces the markdown body of a single
 *     chat message. User messages have their `[mode: X]\n` prefix stripped
 *     (the mode badge is rendered separately in the UI; the user does not
 *     want it re-pasted). Assistant messages concatenate their optional
 *     `thinking` block and their `content`, separated by a `---` rule so
 *     the thinking stays visually distinct in the pasted output.
 *   - `formatApiLogsAsJson(apiLogs)` mirrors exactly what the
 *     `<ApiLogsBlock>` renders in its `<pre>` — a 2-space-indented
 *     JSON.stringify of each log entry's payload, in original order.
 *     This is the format a developer would want to paste into a ticket
 *     or a JSON pretty-printer.
 */

import { stripModePrefix } from "./stripModePrefix.js";

/**
 * Returns the plain-text body of a chat message in markdown form. The
 * returned string is what gets written to the clipboard when the user
 * clicks the per-message "Copy as markdown" button.
 *
 * Behavior by `message.role`:
 *   - `user`: returns `content` with the `[mode: X]\n` prefix removed
 *     (the user's own typed text, with the LLM-facing mode prefix gone).
 *   - `assistant`: returns `thinking` (if non-empty) + `content`,
 *     separated by a horizontal rule `---`. If `content` is empty but
 *     `thinking` is present, returns just the thinking.
 *   - `system`: returns `content` as-is (the system prompt the LLM saw).
 *   - `tool`: returns `content` (the tool's textual result).
 *   - any other role: returns `content` as-is.
 *
 * Returns an empty string if `content` is null/undefined/empty and there
 * is no `thinking` to fall back on, so the button is safe to wire up
 * against any message.
 */
export function messageToMarkdown(message) {
  if (!message || typeof message !== "object") return "";

  const role = message.role;
  const content = typeof message.content === "string" ? message.content : "";
  const thinking = typeof message.thinking === "string" ? message.thinking : "";

  if (role === "user") {
    return stripModePrefix(content, message.mode ?? "");
  }

  if (role === "assistant") {
    if (thinking && content) return `${thinking}\n\n---\n\n${content}`;
    if (thinking) return thinking;
    return content;
  }

  return content;
}

/**
 * Returns the clipboard-ready text for an API logs block — the same
 * 2-space-indented JSON dump the block renders, with one entry per
 * line, separated by a blank line. The output is exactly what
 * `JSON.stringify(log.payload, null, 2)` produces for each log,
 * concatenated in the original order.
 *
 * Returns an empty string for an empty/null input so callers can wire
 * the button up unconditionally.
 */
export function formatApiLogsAsJson(apiLogs) {
  if (!Array.isArray(apiLogs) || apiLogs.length === 0) return "";
  return apiLogs
    .map((log) => JSON.stringify(log?.payload ?? null, null, 2))
    .join("\n\n");
}
