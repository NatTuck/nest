/**
 * Helper functions that derive legacy message fields from the
 * canonical `parts` wire format. Shared between the live
 * rendering path (ChatPage.jsx) and the archived-history pane
 * (CollapsedHistory.jsx) so a re-broadcast assistant message
 * renders identically in both contexts.
 *
 * `splitReasoning/1` is the module's one decision about what is reasoning and
 * what is prose; `thinkingFor/1`, `textPartsFor/1` and the clipboard all read
 * it, so the box, the body and the copy cannot disagree.
 */

import { leadingThinkBlock } from "./thinkTags.js";
import { stripHeader } from "./stripHeader.js";
import { stripAgentHeaderMode } from "./agentHeader.js";
import { messageText } from "./messageText.js";

// A message's reasoning channel and its prose, decided **once** for both the
// thinking box (`thinkingFor`) and the body (`textPartsFor` / the clipboard),
// so the two cannot disagree about what was moved.
//
// The rule, in order:
//
//   * a `Part.Thinking` exists -> that IS the reasoning channel. The text is
//     prose and is never scanned for tags.
//   * else, an assistant row whose first text part opens with a matched
//     `<think>…</think>` -> that leading block is legacy reasoning, and what
//     follows it is prose.
//   * else -> the text is prose, never scanned.
//
// `parts` keeps the message's own shape — same length, same order, same
// indexes — because callers address parts by their index into
// `message.parts` (the wire's `commandOutputParts` does). A reasoning part
// stays in place and a caller that renders text skips it by kind.
//
// A second `Part.Thinking` throws. `build_assistant_parts/1` is the only
// producer and emits at most one, first; a second is a server bug, and
// silently concatenating it would invent reasoning that the row does not have.
export function splitReasoning(message) {
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  const thinking = parts.filter((p) => p?.kind === "thinking");

  if (thinking.length > 1) {
    throw new Error(
      `a message may carry at most one thinking part, got ${thinking.length}: ` +
        "Nest.Agents.Agent.Turn.Messages.build_assistant_parts/1 emits at most one, first",
    );
  }

  if (thinking.length === 1) {
    return { thinking: thinking[0].thinking || null, parts };
  }

  if (message?.role !== "assistant") return { thinking: null, parts };

  const index = parts.findIndex((p) => p?.kind === "text");
  if (index === -1) return { thinking: null, parts };

  const block = leadingThinkBlock(parts[index].text);
  if (!block) return { thinking: null, parts };

  const next = parts.slice();
  next[index] = { ...parts[index], text: block.rest };
  return { thinking: block.thinking || null, parts: next };
}

// The thinking content for a message: `splitReasoning`'s channel, falling back
// to the legacy `message.thinking` field (seen on wire-format messages that
// pre-date the parts cleanup). A user row or a system row never has either, so
// no row grows an invented reasoning box.
export function thinkingFor(message) {
  if (!message) return null;

  return splitReasoning(message).thinking || message.thinking || null;
}

// The parts for a non-user row, with the reasoning removed and any wire
// framing stripped from the first text part. NOT text-only: every non-text part
// passes through in place, `media` included, so a caller that renders the media
// itself must use `messageContentPartsFor` instead (issue #115). A user row does
// not come through here at all — `userPartsFor` renders it segment by segment —
// so this is only used for non-user rows.
//
// A non-user row can still carry wire framing: a transcript recorded before the
// `[From … | mode: …]` header has the retired `[nest notice]` marker at the
// head of a runtime notice's text (and a fused `assistant(notice + ack)` row
// puts it at the head of an assistant row). The framing is stripped from the
// first text part here — the same render-time removal `stripFraming` performs
// for a user row — so the operator sees the words, not the wire. Only the first
// text part is touched: a header or a marker always heads a body, never
// mid-text.
export function textPartsFor(message) {
  const { parts } = splitReasoning(message);
  return stripHeaderFromParts(
    parts.filter((part) => part?.kind !== "thinking"),
    message,
  );
}

function stripHeaderFromParts(parts, message) {
  const index = parts.findIndex((part) => part?.kind === "text");
  if (index === -1) return parts;

  const stripped = stripHeader(parts[index].text, message?.mode);
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
// A `user` row does not come through here — `userPartsFor` renders it segment
// by segment, media included, because its text parts are not uniformly prose.
export function messageContentPartsFor(message) {
  return textPartsFor(message).filter((p) => p?.kind !== "media");
}

// A user-role row's renderable blocks, in wire order, as
// `{kind: "text" | "output", text, index}`.
//
// A user row's `parts` can hold more than one `text` part. A backgrounded
// command's result is the prose that announces it plus the command's own
// output (issue #139), and a drained batch holds one body per entry. The two
// are rendered differently — prose as markdown, a command's output as command
// output — so the caller needs them as separate segments rather than as one
// joined string.
//
// The `[From … | mode: …]` header (and the retired `[Message from agent …]`
// label's mode clause) is stripped from a prose part rather than once from the
// joined text, which is what the joined renderer did before. Per part is the
// same removal for prose: a header heads a body and a `:text` part starts one,
// so no header can sit mid-part at a boundary the join would have seen.
//
// An `:output` part is the exception, and it is why the kind has to be decided
// before the text is touched: a command's output is the **tail** of a body, not
// a head — the header is on the part before it — so its text is exactly the
// bytes the command printed. `stripHeader` treats the first line of whatever
// string it is given as a body head (`kept` starts empty), so stripping an
// output part would delete a first line that merely looks like wire framing: a
// command that prints `[nest notice]`, or a line that happens to match this
// row's own header. That is the one place the operator is meant to see the
// command's own bytes, so an output part's text is passed through untouched.
//
// `commandOutputParts` names indexes into `message.parts` — not into this
// array — so each part's original index is what marks its block. That is what
// keeps a `media` part before the text from shifting the output's position,
// and it is why the output part is not assumed to be last (a drained batch can
// hold several bodies). `index` is that same original index, carried on the
// block so the renderer has a stable identity to key on; a legacy row's single
// block reports `0`.
export function userPartsFor(message) {
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  const outputIndexes = commandOutputIndexes(message, parts);

  const blocks = [];
  for (const [index, part] of parts.entries()) {
    if (!part || part.kind !== "text") continue;
    const isOutput = outputIndexes.has(index);
    blocks.push({
      kind: isOutput ? "output" : "text",
      text: isOutput ? part.text : stripFraming(part.text, message?.mode),
      index,
    });
  }

  if (blocks.length > 0) return blocks;

  // Rows persisted before the parts model carry their text in `content` only
  // (`messageText` is the one place that fallback lives).
  return [
    {
      kind: "text",
      text: stripFraming(messageText(message), message?.mode),
      index: 0,
    },
  ];
}

// The wire framing a user row's body carries and the operator must not see:
// the `[From … | mode: …]` header, and the retired label's mode clause (the
// row's badge already shows the mode).
function stripFraming(text, mode) {
  return stripAgentHeaderMode(stripHeader(text, mode), mode);
}

// The set of `message.parts` indexes `commandOutputParts` names.
//
// The value decides how text is rendered, so a malformed one is a server bug
// that has to be loud rather than silently ignored — this project does not
// hide what it cannot render (AGENTS.md, "UI Transparency"). Anything other
// than an array of non-negative integers, or an index that is not a `text`
// part, throws naming the offending value. `null` is not "absent": the wire
// contract omits the key when there is no command output, so a `null` is a
// disagreement with it and is reported like any other wrong value.
//
// Exported because the clipboard needs the same rule: a command's output is
// copied byte for byte (issue #139), and `formatMessage.js` may not strip wire
// framing from a part this set names.
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
