/**
 * Helpers for `addChatMessage` (message merge + legacy field derivation).
 * Split from `store/index.js`.
 */

import { legacyToParts } from "../helpers";
import {
  graphemeCount,
  graphemeLast,
  graphemeSlice,
} from "../../utils/grapheme.js";

export function messageText(m) {
  if (!m) return "";
  if (Array.isArray(m.parts)) {
    const out = m.parts
      .filter((p) => p && p.kind === "text")
      .map((p) => p.text || "")
      .join("");
    if (out) return out;
  }
  return typeof m.content === "string" ? m.content : "";
}

export function toolCallsFromParts(parts) {
  if (!Array.isArray(parts)) return null;
  const tcs = parts.filter((p) => p && p.kind === "tool_use");
  if (tcs.length === 0) return null;
  return tcs.map((p) => ({
    id: p.id,
    name: p.name,
    arguments: p.arguments || {},
  }));
}

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

export function partsShape(m) {
  if (!m) return [];
  if (Array.isArray(m.parts)) return m.parts;
  if (m.role === "assistant" && Array.isArray(m.toolCalls)) {
    return m.toolCalls.map((tc) => ({
      kind: "tool_use",
      id: tc.id,
      name: tc.name,
      arguments: tc.arguments || {},
    }));
  }
  if (m.role === "tool" && Array.isArray(m.toolResults)) {
    return m.toolResults.map((tr) => ({
      kind: "tool_result",
      toolCallId: tr.tool_call_id,
      name: tr.name,
      content: tr.content || "",
      isError: !!tr.is_error,
    }));
  }
  return [];
}

export function computeMergedThinking(message, streaming) {
  const fromParts = (parts) => {
    if (!Array.isArray(parts)) return null;
    const text = parts
      .filter((p) => p && p.kind === "thinking")
      .map((p) => p.thinking || "")
      .join("");
    return text || null;
  };

  const direct = fromParts(message.parts) ?? message.thinking;

  const streamingParts =
    (streaming?.parts ?? []).length > 0
      ? streaming.parts
      : legacyToParts(streaming).parts;

  const fromStreaming = streamingParts.length
    ? streamingParts
        .filter((p) => p && p.kind === "thinking")
        .map((p) => p.thinking || "")
        .join("")
    : null;

  if (fromStreaming && fromStreaming.length > (direct?.length ?? 0)) {
    console.error(
      "[NEST REGRESSION] Broadcast thinking shorter than streaming partial; " +
        "fell back to streaming partial. " +
        "Server may be dropping/summarizing thinking on tool-call finalization.",
      { broadcast: direct, streaming: fromStreaming },
    );
    return fromStreaming;
  }
  if (direct) return direct;
  if (fromStreaming) return fromStreaming;
  return null;
}

export function buildMerged(m, message, mergedThinking) {
  const mergedApiLogs = message.apiLogs?.length
    ? message.apiLogs
    : m.apiLogs || [];
  const newToolCalls = toolCallsFromParts(message.parts) || [];
  const mergedToolCalls = newToolCalls.length
    ? newToolCalls
    : toolCallsFromParts(partsShape(m)) || [];
  const newToolResults = toolResultsFromParts(message.parts) || [];
  const mergedToolResults = newToolResults.length
    ? newToolResults
    : toolResultsFromParts(partsShape(m)) || [];

  return {
    ...message,
    content: messageText(message) || m.content || "",
    thinking: mergedThinking,
    apiLogs: mergedApiLogs,
    toolCalls: mergedToolCalls,
    toolResults: mergedToolResults,
  };
}

export function warnMessageDiffers(
  id,
  message,
  streaming,
  streamingContent,
  messageContent,
) {
  const extraInPartial =
    graphemeCount(streamingContent) > graphemeCount(messageContent)
      ? graphemeSlice(streamingContent, graphemeCount(messageContent))
      : null;
  const extraInMessage =
    graphemeCount(messageContent) > graphemeCount(streamingContent)
      ? graphemeSlice(messageContent, graphemeCount(streamingContent))
      : null;

  console.warn(`[agent:${id}] Final message differs from partial:`, {
    index: message.index,
    partial: {
      graphemeCount: graphemeCount(streamingContent),
      charsReceived: streaming.charsReceived,
      content:
        graphemeCount(streamingContent) > 200
          ? `...${graphemeLast(streamingContent, 100)}`
          : streamingContent,
    },
    message: {
      graphemeCount: graphemeCount(messageContent),
      content:
        graphemeCount(messageContent) > 200
          ? `...${graphemeLast(messageContent, 100)}`
          : messageContent,
    },
    diff: {
      extraInPartial,
      extraInMessage,
      lengthDiff:
        graphemeCount(streamingContent) - graphemeCount(messageContent),
    },
  });
}
