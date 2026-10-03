/**
 * `addChatMessage` (finalized message merge + optimistic reconcile) and
 * `addUserMessage` (optimistic add). Split from `store/index.js`.
 */

import { legacyToParts, partialPartsToText } from "../helpers";
import {
  buildMerged,
  computeMergedThinking,
  messageText,
  partsShape,
  toolCallsFromParts,
  toolResultsFromParts,
  warnMessageDiffers,
} from "./messageHelpers";

export function addChatMessage(set, get, id, message) {
  const cache = get().agentsCache[id];
  if (!cache) return { applied: false, needsSync: false };

  let matchedIndex = -1;

  set((state) => {
    const cache = state.agentsCache[id];
    if (!cache) return state;

    const streaming = cache.streaming || cache.partial;
    const streamingIndex = streaming?.messageIndex ?? streaming?.index;
    if (streaming && streamingIndex === message.index) {
      const parts = (streaming.parts ?? []).length
        ? streaming.parts
        : legacyToParts(streaming).parts;
      const streamingContent = partialPartsToText(parts);
      const messageContent = messageText(message);
      if (streamingContent !== messageContent) {
        warnMessageDiffers(
          id,
          message,
          streaming,
          streamingContent,
          messageContent,
        );
      }
    }

    matchedIndex = cache.messages.findIndex((m) => m.index === message.index);

    // The content fallback exists only to reconcile the local optimistic
    // echo of the user's own message with the server-stamped copy (whose
    // index can differ, e.g. after a notice pair). It must stay user-only:
    // a tool_use-only assistant has no text, so matching assistants on
    // empty content would fold a new trailing tool call into an older
    // bubble and hide a real message from the timeline.
    if (matchedIndex === -1 && message.role === "user") {
      const recentThresholdMs = 30_000;
      const now = Date.now();
      const incomingContent = messageText(message);
      matchedIndex = cache.messages.findIndex((m) => {
        if (m.role !== message.role) return false;
        if (messageText(m) !== incomingContent) return false;
        const ts = m.timestamp ? Date.parse(m.timestamp) : 0;
        if (Number.isNaN(ts)) return false;
        return now - ts < recentThresholdMs;
      });
    }

    const mergedThinking = computeMergedThinking(message, streaming);

    const newMessages =
      matchedIndex === -1
        ? [
            ...cache.messages,
            {
              ...message,
              content: messageText(message) || message.content || "",
              thinking: mergedThinking,
              toolCalls:
                toolCallsFromParts(message.parts) ||
                toolCallsFromParts(partsShape(message)) ||
                [],
              toolResults:
                toolResultsFromParts(message.parts) ||
                toolResultsFromParts(partsShape(message)) ||
                [],
            },
          ]
        : cache.messages.map((m, i) =>
            i === matchedIndex ? buildMerged(m, message, mergedThinking) : m,
          );

    return {
      agentsCache: {
        ...state.agentsCache,
        [id]: {
          ...cache,
          messages: newMessages,
          streaming: null,
          partial: null,
          lastIndex: message.index,
        },
      },
    };
  });

  const snapshotLastIndex = cache.lastIndex ?? -1;
  const needsSync =
    matchedIndex === -1 &&
    message.index > snapshotLastIndex + 1 &&
    snapshotLastIndex >= 0;

  return { applied: true, needsSync, snapshotLastIndex };
}

export function addUserMessage(set, id, content, mode) {
  set((state) => {
    const cache = state.agentsCache[id];
    if (!cache) return state;

    const newIndex = cache.lastIndex + 1;
    const userMessage = {
      index: newIndex,
      role: "user",
      parts: [{ kind: "text", text: content }],
      content,
      mode,
      timestamp: new Date().toISOString(),
    };

    const streamingState = {
      messageIndex: newIndex + 1,
      role: "assistant",
      nextDeltaIndex: 0,
      parts: [],
      currentKind: null,
    };

    const partialState = {
      index: newIndex + 1,
      role: "assistant",
      charsReceived: 0,
      parts: [],
      currentKind: null,
    };

    return {
      agentsCache: {
        ...state.agentsCache,
        [id]: {
          ...cache,
          messages: [...cache.messages, userMessage],
          lastIndex: newIndex,
          waitingForResponse: true,
          streaming: streamingState,
          partial: partialState,
          notification: null,
        },
      },
    };
  });
}
