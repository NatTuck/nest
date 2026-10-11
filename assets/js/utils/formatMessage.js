/**
 * Convert chat messages and API log arrays to plain-text representations
 * suitable for clipboard copy.
 *
 *   - `messageToMarkdown(message)` produces the markdown body of a single
 *     chat message. It walks the message's canonical `parts` in order and
 *     serialises every part, with one deliberate exception: reasoning is
 *     omitted from the clipboard (issue #51). That covers both a
 *     `thinking` part and reasoning embedded as `<think>…</think>` inside
 *     a `text` part (the UI routes the latter to the `ThinkingBlock` via
 *     `splitThinkFromParts`; see `Message.jsx`). User messages are copied
 *     verbatim — the UI shows a user's own text as-is, so the clipboard
 *     must not silently drop a `<think>` they typed. User messages also
 *     have their `[mode: X]\n` prefix stripped (the mode badge is rendered
 *     separately in the UI; the user does not want it re-pasted). Tool
 *     calls and tool results have no natural markdown form, so they are
 *     rendered as a bold header plus a fenced code block; a part kind this
 *     build does not recognise is called out in the output rather than
 *     silently dropped.
 *   - `formatApiLogsAsJson(apiLogs)` mirrors exactly what the
 *     `<ApiLogsBlock>` renders in its `<pre>` — a 2-space-indented
 *     JSON.stringify of each log entry's payload, in original order.
 *     This is the format a developer would want to paste into a ticket
 *     or a JSON pretty-printer.
 */

import { stripModePrefix } from "./stripModePrefix.js";
import { splitThinkFromParts } from "./thinkTags.js";

// The clipboard omits reasoning on purpose (issue #51). When a message
// carries *only* reasoning, the copy would otherwise be empty — which reads
// as a failure. Say what happened instead.
const THINKING_OMITTED_MARKER = "*[thinking omitted from copy]*";

/**
 * Returns the clipboard-ready markdown body of a chat message: every part
 * in `message.parts`, in order, except reasoning.
 *
 * Behavior:
 *   - `parts` present and non-empty: serialise each part in order (see
 *     `partToMarkdown`). Reasoning contributes nothing; if that leaves no
 *     other part, the output is `THINKING_OMITTED_MARKER` so the copy is
 *     non-empty and honest about the omission.
 *   - no `parts` (legacy shape): fall back to `content` only — reasoning
 *     is still excluded, so a legacy assistant's `thinking` field is not
 *     copied.
 *
 * Returns an empty string for a null/non-object message, or for a message
 * with no copyable content, so the button is safe to wire up against any
 * message.
 */
export function messageToMarkdown(message) {
  if (!message || typeof message !== "object") return "";

  const role = message.role;
  const mode = message.mode ?? "";

  if (Array.isArray(message.parts) && message.parts.length > 0) {
    const blocks = message.parts
      .map((part) => partToMarkdown(part, role, mode))
      .filter((block) => block !== "");
    if (blocks.length > 0) return blocks.join("\n\n");
    // Every part was reasoning (or otherwise unrenderable) — see above.
    return message.parts.some((part) => part && part.kind === "thinking")
      ? THINKING_OMITTED_MARKER
      : "";
  }

  const raw = typeof message.content === "string" ? message.content : "";
  const out = role === "user" ? stripModePrefix(raw, mode) : visibleText(raw);
  if (out !== "") return out;
  // A legacy message (no `parts`) whose only content is its `thinking`
  // field: same treatment as the parts path above.
  if (typeof message.thinking === "string" && message.thinking !== "") {
    return THINKING_OMITTED_MARKER;
  }
  return "";
}

/**
 * Serialise a single part to markdown, or `""` for a part that
 * contributes nothing (reasoning, or a malformed entry).
 */
function partToMarkdown(part, role, mode) {
  if (!part || typeof part !== "object") return "";

  switch (part.kind) {
    case "text": {
      const text = typeof part.text === "string" ? part.text : "";
      // A user's own text is copied verbatim (that is what the UI shows);
      // everyone else's text has embedded `<think>` reasoning removed.
      return role === "user" ? stripModePrefix(text, mode) : visibleText(text);
    }
    case "thinking":
      // Deliberately excluded from the clipboard (issue #51). The UI
      // still renders it; only the copy omits it.
      return "";
    case "refusal":
      return part.refusal || "";
    case "tool_use":
      return toolUseToMarkdown(part);
    case "tool_result":
      return toolResultToMarkdown(part);
    default:
      // A kind this build does not know. Never drop it silently.
      return `*[unsupported part omitted from copy: ${part.kind ?? "unknown"}]*`;
  }
}

/**
 * The user-visible text of a string: everything outside `<think>…</think>`.
 * Reasoning embedded in a text part is not copyable either — the UI already
 * routes it to the `ThinkingBlock`, so the clipboard must not leak it
 * (issue #51, requirement 2). Reuses `splitThinkFromParts`, the same split
 * the UI renders through, rather than re-deriving the extraction.
 */
function visibleText(text) {
  return splitThinkFromParts([{ kind: "text", text }])
    .textParts.map((part) => part.text)
    .join("");
}

/** A tool call: a bold header naming the tool, then its arguments. */
function toolUseToMarkdown(part) {
  const name = part.name || "unknown";
  const header = `**Tool call: \`${name}\`**`;
  // `arguments` carries the finalised object or the streaming buffer; a
  // streaming accumulator may instead hold the raw buffer in `text`.
  const args = argumentsToBlock(part.arguments) || argumentsToBlock(part.text);
  return args ? `${header}\n\n${args}` : header;
}

/**
 * A tool result: a bold header naming the tool and its outcome, then the
 * call's arguments (when present) and the result body. The outcome words
 * mirror the badges `ToolResults.jsx` renders, including the verbatim
 * handling of an unrecognised `state`.
 */
function toolResultToMarkdown(part) {
  const name = part.name || "unknown";
  const blocks = [`**Tool result: \`${name}\` — ${resultLabel(part)}**`];
  const args = argumentsToBlock(part.arguments);
  if (args) blocks.push(args);
  const body = toolResultBody(part);
  if (body !== "") blocks.push(codeBlock(body));
  return blocks.join("\n\n");
}

/**
 * The body of a tool result: `content` when present, falling back to the
 * raw `text` buffer a streaming accumulator carries it in.
 */
function toolResultBody(part) {
  if (typeof part.content === "string" && part.content !== "") {
    return part.content;
  }
  return typeof part.text === "string" ? part.text : "";
}

/** The outcome label for a tool result, matching `ToolResults.jsx`. */
function resultLabel(part) {
  if (part.state === "backgrounded") return "Backgrounded";
  if (part.state) return `Unknown state (${part.state})`;
  return part.isError ? "Error" : "Success";
}

/**
 * A fenced JSON block for an `arguments` value, or `""` when there is
 * nothing to show. `arguments` is an object once finalised, a
 * partial-JSON string while streaming, or empty.
 */
function argumentsToBlock(args) {
  if (args && typeof args === "object") {
    const json = JSON.stringify(args, null, 2);
    return json && json !== "{}" ? codeBlock(json, "json") : "";
  }

  if (typeof args === "string" && args.trim() !== "") {
    return codeBlock(args, "json");
  }

  return "";
}

/**
 * Wrap `content` in a fenced code block. The fence is one backtick longer
 * than the longest backtick run inside the content (minimum three), so a
 * shell result that itself contains a ``` fence cannot break out.
 */
function codeBlock(content, language = "") {
  const fence = "`".repeat(Math.max(3, longestBacktickRun(content) + 1));
  return `${fence}${language}\n${content}\n${fence}`;
}

/** Length of the longest run of backticks in `text`. */
function longestBacktickRun(text) {
  let longest = 0;
  let current = 0;
  for (const ch of text) {
    if (ch === "`") {
      current += 1;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return longest;
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
