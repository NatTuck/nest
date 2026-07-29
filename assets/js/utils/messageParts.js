/**
 * Helper functions that derive legacy message fields from the
 * canonical `parts` wire format. Shared between the live
 * rendering path (ChatPage.jsx) and the archived-history pane
 * (CollapsedHistory.jsx) so a re-broadcast assistant message
 * renders identically in both contexts.
 */

import { splitThinkFromParts } from "./thinkTags.js";

// Concatenate the thinking content for an assistant message:
// both `Part.Thinking` entries AND any `<think>...</think>`
// blocks buried in `Part.Text` text. If `message.parts` carries
// no thinking, falls back to the legacy `message.thinking`
// field (seen on wire-format messages that pre-date the parts
// cleanup).
export function thinkingFor(message) {
  if (!message) return null;

  const fromParts = splitThinkFromParts(message.parts).thinking;
  if (fromParts) return fromParts;

  return message.thinking || null;
}

// Extract the text parts for an assistant message, with any
// `<think>...</think>` blocks removed (their content was
// routed into the ThinkingBlock above). For user messages, the
// caller wraps the text in a single Part.Text (with the mode
// prefix stripped), so this is only used for assistants.
export function textPartsFor(message) {
  return splitThinkFromParts(message?.parts).textParts;
}

// Derive the legacy `toolCalls` shape from a message's `parts`
// (the wire format). Returns `null` when no `tool_use` parts
// are present, mirroring the live-area derivation in
// `addChatMessage` so a re-broadcast tool-call message renders
// the same in the history pane.
//
// `arguments` is JSON-decoded when it's a string (the
// streaming shape appends fragments into a string buffer),
// and passed through unchanged when it's already an object
// (the finalized / DB-restored shape).
export function toolCallsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const tcs = parts.filter((p) => p && p.kind === "tool_use");
  if (tcs.length === 0) return null;
  return tcs.map((p) => ({
    id: p.id,
    name: p.name,
    arguments: decodeArguments(p.arguments),
  }));
}

function decodeArguments(args) {
  if (typeof args !== "string") return args || {};
  if (args === "") return {};
  try {
    const parsed = JSON.parse(args);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
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
