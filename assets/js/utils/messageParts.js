/**
 * Helper functions that derive legacy message fields from the
 * canonical `parts` wire format. Shared between the live
 * rendering path (ChatPage.jsx) and the archived-history pane
 * (CollapsedHistory.jsx) so a re-broadcast assistant message
 * renders identically in both contexts.
 */

import { splitThinkFromParts } from "./thinkTags.js";
import { stripNoticePrefix } from "./stripNoticePrefix.js";

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

// The parts for a non-user row, with any `<!--think...-->` blocks split
// out (their content was routed into the ThinkingBlock above). NOT
// text-only: every non-text part passes through in place, `media`
// included, so a caller that renders the media itself must use
// `messageContentPartsFor` instead (issue #115). For user messages, the
// caller wraps the text in a single Part.Text (with the mode prefix
// stripped), so this is only used for non-user rows.
//
// A synthetic runtime notice renders into an assistant row too: the fused
// `assistant(notice + ack)` shape puts the `[nest notice]` marker at the head
// of the row's text (`Nest.Agents.Agent.NoticePairInjector`). The marker is
// stripped from the first text part here — the same render-time removal
// `stripModePrefix` performs for a user row's `[mode: X]` prefix — so the
// operator sees the notice, not the wire framing. Only the first text part is
// touched: the marker is always at the head of the row, never mid-text.
export function textPartsFor(message) {
  return stripNoticeFromParts(splitThinkFromParts(message?.parts).textParts);
}

function stripNoticeFromParts(parts) {
  const index = parts.findIndex((part) => part?.kind === "text");
  if (index === -1) return parts;

  const stripped = stripNoticePrefix(parts[index].text);
  if (stripped === parts[index].text) return parts;

  const next = parts.slice();
  next[index] = { ...parts[index], text: stripped };
  return next;
}

// The parts to hand `MessageContent` for a non-user row, whose media is
// rendered beside it rather than inside it.
//
// `textPartsFor` passes every non-text part through, and `media` is the one
// kind `MessageContent` renders itself (`mediaFromParts` + `ToolMedia`), so
// a caller that renders the media with its own `ToolMedia` would render the
// attachment a second time and the operator would see it twice (issue #115).
// Filtering it out here is the whole contract. The `tool_use` / `tool_result`
// parts stay: `MessageContent` reads only `text` and ignores them, and
// `toolCallsFromParts` / `toolResultsFromParts` derive their shapes from the
// message's own parts, not from what this returns.
//
// A `user` row does not come through here — that branch synthesises its own
// parts array and hands its media to `MessageContent` to render.
export function messageContentPartsFor(message) {
  return textPartsFor(message).filter((p) => p?.kind !== "media");
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
// text block with real newlines so a `file-write` body or a long
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
//   * `{kind: "stream-long"}` — `file-write`-style / long-command
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
// "long content" preview field for `file-write` bodies and
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
//
// `state` is passed through verbatim (and is `null` for an ordinary
// result): the panel badges on it, so a value this build does not know
// must reach it rather than being mapped away here.
export function toolResultsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const trs = parts.filter((p) => p && p.kind === "tool_result");
  if (trs.length === 0) return null;
  return trs.map((p) => ({
    tool_call_id: p.toolCallId,
    name: p.name,
    content: p.content || "",
    is_error: !!p.isError,
    state: p.state ?? null,
  }));
}

// Derive the media attachments from a message's `parts` (issue #40).
// Returns `null` when there are none — the same contract as
// `toolResultsFromParts`, so a caller can use `?? []` and a caller that
// wants to skip the render can test for null.
//
// `data` stays base64 (the component builds the `data:` URI) and `path`
// is `null` rather than `undefined` when the wire omitted it, so the
// renderer's `media.path && ...` guard is the only missing-data check it
// needs.
export function mediaFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const media = parts.filter((p) => p && p.kind === "media");
  if (media.length === 0) return null;
  return media.map((p) => ({
    tool_call_id: p.toolCallId,
    modality: p.modality,
    mediaType: p.mediaType,
    bytes: p.bytes,
    data: p.data,
    path: p.path ?? null,
  }));
}
