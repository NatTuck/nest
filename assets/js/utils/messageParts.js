/**
 * Helper functions that derive legacy message fields from the
 * canonical `parts` wire format. Shared between the live
 * rendering path (ChatPage.jsx) and the archived-history pane
 * (CollapsedHistory.jsx) so a re-broadcast assistant message
 * renders identically in both contexts.
 */

import { splitThinkFromParts } from "./thinkTags.js";

// Concatenate the thinking content for an assistant message:
// both `Part.Thinking` entries AND any `<!--think...-->` blocks buried
// in `Part.Text` text. If `message.parts` carries no thinking, falls
// back to the legacy `message.thinking` field (seen on wire-format
// messages that pre-date the parts cleanup).
export function thinkingFor(message) {
  if (!message) return null;

  const fromParts = splitThinkFromParts(message.parts).thinking;
  if (fromParts) return fromParts;

  return message.thinking || null;
}

// Extract the text parts for an assistant message, with any
// `<!--think...-->` blocks removed (their content was routed into
// the ThinkingBlock above). For user messages, the caller wraps
// the text in a single Part.Text (with the mode prefix stripped), so
// this is only used for assistants.
export function textPartsFor(message) {
  return splitThinkFromParts(message?.parts).textParts;
}

// Derive the legacy `toolCalls` shape from a message's `parts`
// (the wire format). Returns `null` when no `tool_use` parts
// are present, mirroring the live-area derivation in
// `addChatMessage` so a re-broadcast tool-call message renders
// the same in the history pane.
//
// `arguments` is passed through unchanged (string during streaming,
// object when finalized) so the renderer can pick the right
// presentation per call. The legacy behavior of decoding partial
// JSON to `{}` lost the streaming preview; see `formatToolCall`
// below for the streaming-aware rendering decision.
export function toolCallsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const tcs = parts.filter((p) => p && p.kind === "tool_use");
  if (tcs.length === 0) return null;
  return tcs.map((p) => ({
    id: p.id,
    name: p.name,
    arguments: p.arguments == null ? "" : p.arguments,
  }));
}

// Heuristic thresholds used by `formatToolCall` to decide when a
// streaming argument buffer has crossed from "monospace JSON is
// fine" into "this is a long content field — render it as a plain
// text block with real newlines so a `write_file` body or a long
// shell command reads naturally".
export const LONG_FIELD_THRESHOLD = 300;
export const LONG_TOTAL_THRESHOLD = 800;

// Decide how to render a tool call's arguments for the live
// streaming bubble. The caller passes a `call` of shape
// `{id, name, arguments}` where `arguments` may be:
//
//   * `""` — the call started but no deltas have arrived yet.
//   * a partial JSON string `'{"command":'` (streaming fragment).
//   * a parsed object `{command: "ls"}` (the finalized / DB shape).
//
// Returns a discriminated union the renderer branches on:
//
//   * `{kind: "empty"}`     — render only the "Using tool: <name>" line.
//   * `{kind: "stream-short"}` — monospace buffer in a `<pre>`, newlines
//     preserved (`whitespace-pre-wrap`). Best for short tool calls.
//   * `{kind: "stream-long"}` — `write_file`-style / long-command
//     rendering: a path header + a plain-text body block with real
//     newlines, plus compact metadata for the remaining fields.
//   * `{kind: "object"}`    — finalized object; the existing
//     `<TruncatedResult>` JSON preview path.
export function formatToolCall(call) {
  if (!call) return { kind: "empty" };
  const { arguments: args } = call;

  const isEmpty =
    args == null || (typeof args === "string" && args.length === 0);
  if (isEmpty) return { kind: "empty" };

  // Already-parsed object: fall through to the existing
  // TruncatedResult path. Pass it through unchanged so
  // sortArgumentsForDisplay still gets a real object.
  if (typeof args !== "string") {
    return { kind: "object", value: args };
  }

  // Streaming string buffer. Try to parse opportunistically —
  // partial JSON parses will throw and we drop back to raw.
  let parsed = null;
  try {
    parsed = JSON.parse(args);
  } catch {
    parsed = null;
  }

  const longField = findLongStringField(parsed, LONG_FIELD_THRESHOLD);
  const totalLen = args.length;
  const isLong = !!longField || totalLen >= LONG_TOTAL_THRESHOLD;

  if (!parsed || typeof parsed !== "object") {
    // Treat a non-object primitive (e.g. `args === "42"` —
    // invalid for tool calls but defensive) the same as a
    // partial buffer.
    return isLong
      ? {
          kind: "stream-long",
          raw: args,
          value: {},
          previewField: null,
          preview: args,
        }
      : { kind: "stream-short", raw: args };
  }

  if (isLong && longField) {
    return {
      kind: "stream-long",
      raw: args,
      value: parsed,
      previewField: longField.key,
      preview: longField.value,
    };
  }

  if (isLong && parsed && typeof parsed === "object") {
    // Long raw without a single dominant string field — fall
    // back to monospace raw with real newlines, which still
    // reads cleanly thanks to whitespace-pre-wrap.
    return { kind: "stream-short", raw: args };
  }

  // Small object (parsed): render the formatted JSON. Caller
  // may still flip to stream-short if the JSON eventually
  // grows beyond the threshold on subsequent deltas.
  if (Object.keys(parsed).length > 0 && totalLen < LONG_TOTAL_THRESHOLD) {
    return { kind: "object", value: parsed };
  }

  return { kind: "stream-short", raw: args };
}

// Heuristic: pick the parsed-string field whose value length is
// the largest, provided it crosses the threshold. Returns
// `{key, value}` or `null`. Used by `formatToolCall` to pick the
// "long content" preview field for `write_file` bodies and
// long shell commands.
function findLongStringField(parsed, threshold) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }
  let best = null;
  for (const [key, value] of Object.entries(parsed)) {
    if (typeof value === "string" && value.length >= threshold) {
      if (!best || value.length > best.value.length) {
        best = { key, value };
      }
    }
  }
  return best;
}

// Derive the legacy `toolResults` shape from a message's `parts`.
export function toolResultsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const trs = parts.filter((p) => p && p.kind === "tool_result");
  if (trs.length === 0) return null;
  return trs.map((p) => ({
    tool_call_id: p.toolCallId,
    name: p.name,
    content: p.content || "",
    is_error: !!p.isError,
  }));
}
