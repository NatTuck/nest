/**
 * Convert chat messages and API log arrays to plain-text representations
 * suitable for clipboard copy.
 *
 *   - `messageToMarkdown(message)` produces the markdown body of a single
 *     chat message. It walks the message's canonical `parts` in order and
 *     serialises every part, with one deliberate exception: reasoning is
 *     omitted from the clipboard (issue #51). That covers both a
 *     `thinking` part and reasoning embedded as `<think>…</think>` inside
 *     a `text` part. Which roles get that treatment is decided by
 *     `stripsThinkTags/1`, which mirrors each role's *body* renderer
 *     (`MessageContent` / `SystemMessageContent`; see its docs) — the
 *     clipboard shows what that renderer shows. User messages also have
 *     their `[mode: X]\n` prefix stripped (the mode badge is rendered
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
import { mediaSummary } from "./media.js";

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
    const blocks = [];
    let droppedReasoning = false;
    for (const part of message.parts) {
      const block = partToMarkdown(part, role, mode);
      if (block !== "") {
        blocks.push(block);
      } else if (partIsReasoning(part, role)) {
        droppedReasoning = true;
      }
    }
    if (blocks.length > 0) return blocks.join("\n\n");
    // Nothing copyable. When reasoning was actually omitted, say so rather
    // than copying an empty string.
    return droppedReasoning ? THINKING_OMITTED_MARKER : "";
  }

  const raw = typeof message.content === "string" ? message.content : "";
  const visible = visibleForRole(raw, role, mode);
  if (visible !== "") return visible;
  // Nothing visible. Say so when the content was reasoning: a legacy
  // `thinking` field, or `content` that was entirely `<think>…</think>`.
  const droppedReasoning =
    (typeof message.thinking === "string" && message.thinking !== "") ||
    (stripsThinkTags(role) && raw !== "");
  return droppedReasoning ? THINKING_OMITTED_MARKER : "";
}

/**
 * Serialise a single part to markdown, or `""` for a part that
 * contributes nothing (reasoning, or a malformed entry).
 */
function partToMarkdown(part, role, mode) {
  if (!part || typeof part !== "object") return "";

  switch (part.kind) {
    case "text":
      return visibleForRole(
        typeof part.text === "string" ? part.text : "",
        role,
        mode,
      );
    case "thinking":
      // Deliberately excluded from the clipboard (issue #51). The UI
      // still renders it; only the copy omits it.
      return "";
    case "refusal":
      return typeof part.refusal === "string" ? part.refusal : "";
    case "tool_use":
      return toolUseToMarkdown(part);
    case "tool_arguments":
      // A streaming accumulator part (`store/helpers.js` `newPart/2`)
      // carrying the arguments JSON in `text`. Show it rather than
      // calling it unsupported.
      return (
        argumentsToBlock(part.text) || "*[tool arguments omitted from copy]*"
      );
    case "tool_result":
      return toolResultToMarkdown(part);
    case "media":
      return mediaToMarkdown(part);
    default:
      // A kind this build does not know. Never drop it silently.
      return `*[unsupported part omitted from copy: ${part.kind ?? "unknown"}]*`;
  }
}

/**
 * Serialise a media part to a reference line, never to the payload: a
 * `data:` URI on the clipboard is not useful, and a multi-megabyte base64
 * string would swamp everything else in the copy. The line still names
 * what was attached — type, decoded size, and the path the agent asked
 * for — so the copy says what the panel showed without carrying the bytes.
 */
function mediaToMarkdown(part) {
  return `**Tool media: ${mediaSummary(part)}**`;
}

/**
 * Whether a part produced no block because it was reasoning: a `thinking`
 * part, or a text part whose content was entirely `<think>…</think>`
 * (closed or unclosed) for a role whose body renderer splits those tags.
 */
function partIsReasoning(part, role) {
  if (!part || typeof part !== "object") return false;
  if (part.kind === "thinking") return true;
  if (part.kind !== "text" || !stripsThinkTags(role)) return false;
  const text = typeof part.text === "string" ? part.text : "";
  return text !== "" && visibleText(text) === "";
}

/**
 * Whether this role's *body* renderer splits `<think>` blocks out of its
 * text. `Message.jsx` sends a `user` message's own text through
 * `stripModePrefix(messageText(…))` and a `system` message through
 * `SystemMessageContent` (both raw), while every other role (assistant,
 * tool, …) goes through `textPartsFor` / `splitThinkFromParts`.
 *
 * This concerns the body only. `Message.jsx` also renders a `ThinkingBlock`
 * for every role via `thinkingFor`, but the copy does not consult it —
 * reasoning is the one deliberate omission, and only where the body
 * renderer treats it as reasoning.
 */
function stripsThinkTags(role) {
  return role !== "user" && role !== "system";
}

/**
 * The visible body text for a role, matching that role's body renderer:
 * the `user`'s own text with the mode prefix stripped, a `system` message
 * verbatim, and everyone else with `<think>` reasoning split out.
 */
function visibleForRole(text, role, mode) {
  if (role === "user") return stripModePrefix(text, mode);
  return stripsThinkTags(role) ? visibleText(text) : text;
}

/**
 * The user-visible part of a string: everything outside `<think>…</think>`
 * (or an orphan `</think>`). Reuses `splitThinkFromParts`, the same split
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
 * handling of an unrecognised `state`. The body is copied verbatim, as
 * `ToolResults` renders it.
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
 * `JSON.stringify(log.payload, apiLogReplacer, 2)` produces for each log,
 * concatenated in the original order.
 *
 * Returns an empty string for an empty/null input so callers can wire
 * the button up unconditionally.
 */
export function formatApiLogsAsJson(apiLogs) {
  if (!Array.isArray(apiLogs) || apiLogs.length === 0) return "";
  return apiLogs
    .map((log) => JSON.stringify(log?.payload ?? null, apiLogReplacer, 2))
    .join("\n\n");
}

// A media part's base64 payload is one multi-megabyte string, and the
// API-log `<pre>` would build and lay out all of it (issue #40). Elide any
// string that looks like it carries a large base64 payload, in place, with a
// marker naming its length. Everything else is untouched, so the log still
// shows the whole request shape.
//
// The elision is itself visible data rather than a silent omission, which is
// what keeps this consistent with the project's rule that expected data is
// never quietly dropped — and the *stored* parts are unaffected, so nothing
// is hidden from anyone who wants the bytes.
export const MAX_INLINE_LOG_STRING = 2_048;

// A string is treated as an embedded payload when it is entirely base64, or
// when it contains a long base64 run. The second form is what a provider's
// image reference looks like — `data:image/png;base64,<payload>` — and the
// run length is what keeps a long prose string (whose spaces break the run)
// from being mistaken for one.
//
// A long non-media base64-ish string (a signed token, a hash) is elided too.
// That is benign rather than a defect: the replacement is an explicit,
// length-naming marker rather than a silent omission, so the reader can see
// that something was there and how big it was. The stored parts are untouched
// either way — this runs at render and copy time only.
const BASE64_ONLY_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const BASE64_RUN_RE = /[A-Za-z0-9+/]{1024,}={0,2}/;

export function apiLogReplacer(_key, value) {
  if (
    typeof value === "string" &&
    value.length > MAX_INLINE_LOG_STRING &&
    (BASE64_ONLY_RE.test(value) || BASE64_RUN_RE.test(value))
  ) {
    return `[base64 payload elided: ${value.length} characters]`;
  }
  return value;
}
