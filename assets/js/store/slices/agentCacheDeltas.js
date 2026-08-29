/**
 * `addChatDelta` — the streaming delta accumulator for the zustand store.
 * Split from `store/index.js` (it's one of the largest setters).
 */

import { accumulatePart, applyPartDelta, partialPartsToText } from "../helpers";
import {
  graphemeCount,
  graphemeLast,
  graphemeSlice,
} from "../../utils/grapheme.js";

export function addChatDelta(set, get, id, payload) {
  const state = get();
  const cache = state.agentsCache[id];
  if (!cache) return { applied: false, needsSync: false };

  const messageIndex = payload.messageIndex ?? payload.index;
  const deltaIndex = payload.deltaIndex;
  const charsStart = payload.charsStart;
  const charsEnd = payload.charsEnd;
  const content = payload.content;
  const partType = payload.partType;

  if (deltaIndex !== undefined) {
    const streaming =
      cache.streaming && cache.streaming.messageIndex === messageIndex
        ? cache.streaming
        : {
            messageIndex: messageIndex,
            nextDeltaIndex: 0,
            parts: [],
            currentKind: null,
          };

    if (deltaIndex !== streaming.nextDeltaIndex) {
      const isDuplicate = deltaIndex < streaming.nextDeltaIndex;
      console.warn(
        `[agent:${id}] Delta ${isDuplicate ? "duplicate" : "out of order"}:`,
        {
          messageIndex: messageIndex,
          expectedDeltaIndex: streaming.nextDeltaIndex,
          receivedDeltaIndex: deltaIndex,
        },
      );
      return {
        applied: false,
        needsSync: !isDuplicate,
        outOfOrder: !isDuplicate,
      };
    }

    const newParts =
      partType === "tool_use_start" || partType === "tool_use_delta"
        ? applyPartDelta(streaming.parts || [], partType, payload)
        : accumulatePart(
            streaming.parts || [],
            streaming.currentKind,
            content,
            partType,
          ).parts;
    const newCurrentKind =
      partType === "tool_use_start" || partType === "tool_use_delta"
        ? "tool_use"
        : partType || "text";

    set((s) => ({
      agentsCache: {
        ...s.agentsCache,
        [id]: {
          ...cache,
          streaming: {
            ...streaming,
            nextDeltaIndex: deltaIndex + 1,
            parts: newParts,
            currentKind: newCurrentKind,
            toolCallId: payload.toolCallId || streaming.toolCallId,
            toolCallName: payload.toolCallName || streaming.toolCallName,
          },
          waitingForResponse: false,
        },
      },
    }));
    return { applied: true, needsSync: false };
  }

  const partial =
    cache.partial && cache.partial.index === messageIndex
      ? cache.partial
      : {
          index: messageIndex,
          role: "assistant",
          charsReceived: 0,
          parts: [],
          currentKind: null,
        };

  const existingParts = Array.isArray(partial.parts)
    ? partial.parts
    : partial.content
      ? [{ kind: "text", text: partial.content }]
      : [];
  const existingCurrentKind =
    partial.currentKind ?? (partial.content ? "text" : null);

  if (
    cache.partial &&
    !Array.isArray(cache.partial.parts) &&
    cache.partial.content
  ) {
    set((s) => ({
      agentsCache: {
        ...s.agentsCache,
        [id]: {
          ...cache,
          partial: {
            ...cache.partial,
            content: undefined,
            parts: existingParts,
            currentKind: existingCurrentKind,
          },
        },
      },
    }));
  }

  const currentReceived = partial.charsReceived || 0;
  const isToolUseEvent =
    partType === "tool_use_start" || partType === "tool_use_delta";

  if (charsStart > currentReceived && !isToolUseEvent) {
    return { applied: false, needsSync: true };
  }

  let newContent = content;
  let overlapMismatch = false;
  if (charsStart < currentReceived && !isToolUseEvent) {
    const overlap = currentReceived - charsStart;
    const streamingText = partialPartsToText(existingParts);
    const expectedOverlap = graphemeLast(streamingText, overlap);
    const actualOverlap = graphemeSlice(content, 0, overlap);
    overlapMismatch = expectedOverlap !== actualOverlap;

    if (overlapMismatch) {
      console.warn(`[agent:${id}] Delta overlap mismatch:`, {
        delta: {
          index: messageIndex,
          charsStart: charsStart,
          charsEnd: charsEnd,
          content: content,
          graphemeCount: graphemeCount(content),
        },
        partial: {
          index: partial.index,
          charsReceived: currentReceived,
          graphemeCount: graphemeCount(streamingText),
          content:
            graphemeCount(streamingText) > 100
              ? `...${graphemeLast(streamingText, 50)}`
              : streamingText,
        },
        overlapCalc: {
          overlapChars: overlap,
          expected: expectedOverlap,
          actual: actualOverlap,
        },
        integrityCheck: {
          contentVsCharsReceived:
            graphemeCount(streamingText) === currentReceived
              ? "OK"
              : `MISMATCH: graphemeCount=${graphemeCount(streamingText)}, charsReceived=${currentReceived}`,
        },
      });
    }

    newContent = graphemeSlice(content, overlap);
    if (graphemeCount(newContent) === 0) {
      return { applied: false, needsSync: false, overlapMismatch };
    }
  }

  const { parts: newParts, currentKind: newCurrentKind } = isToolUseEvent
    ? {
        parts: applyPartDelta(existingParts, partType, payload),
        currentKind: "tool_use",
      }
    : accumulatePart(existingParts, existingCurrentKind, newContent, partType);

  const updatedPartial = {
    ...partial,
    content: undefined,
    charsReceived: isToolUseEvent ? (partial.charsReceived ?? 0) : charsEnd,
    parts: newParts,
    currentKind: newCurrentKind,
  };

  set((s) => ({
    agentsCache: {
      ...s.agentsCache,
      [id]: {
        ...cache,
        partial: updatedPartial,
        streaming: { ...updatedPartial, messageIndex },
        waitingForResponse: false,
      },
    },
  }));
  return { applied: true, needsSync: false, overlapMismatch };
}
