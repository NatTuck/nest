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

/**
 * Optimistic add for the user's own message, used before the
 * `chat:message` push resolves.
 *
 * The row is fabricated at `cache.lastIndex + 1`, with an assistant
 * `streaming`/`partial` placeholder at `lastIndex + 2` when no
 * accumulator is already in flight — the normal case appends the
 * server's real message at that index and `addChatMessage` reconciles
 * the two. A send while the agent is streaming must not overwrite the
 * live accumulator: that would drop the streaming text and make the next
 * `chat:delta` look like a gap.
 *
 * When the agent is busy the server only *queues* the message instead,
 * so the fabricated row is retracted once `chat:inbox` confirms it is
 * waiting (`setAgentInbox`), or when the push is rejected
 * (`retractUserMessage`). The row carries `optimistic: true`, a plain
 * bookkeeping field no renderer reads, which marks it as a client-side
 * echo that may still be retracted. The marker is dropped as soon as the
 * row stops being an echo: `addChatMessage` reconciles it with the
 * server's copy (the merge spreads the incoming message), and
 * `setAgentConnected` clears it on the rows a reconnect keeps, because
 * those stand for server state the join just confirmed.
 */
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
      optimistic: true,
      timestamp: new Date().toISOString(),
    };

    // Only fabricate the assistant accumulator when none is in flight.
    // A queued send during a stream must leave the live `partial` alone.
    const inFlight = cache.streaming || cache.partial;
    const placeholders = inFlight
      ? null
      : {
          streaming: {
            messageIndex: newIndex + 1,
            role: "assistant",
            nextDeltaIndex: 0,
            parts: [],
            currentKind: null,
          },
          partial: {
            index: newIndex + 1,
            role: "assistant",
            charsReceived: 0,
            parts: [],
            currentKind: null,
          },
        };

    return {
      agentsCache: {
        ...state.agentsCache,
        [id]: {
          ...cache,
          messages: [...cache.messages, userMessage],
          lastIndex: newIndex,
          waitingForResponse: true,
          ...(placeholders ?? {}),
          notification: null,
        },
      },
    };
  });
}

/**
 * Remove the newest still-`optimistic` row whose `content` matches,
 * returning the cache fields to patch, or `null` when there is no match.
 *
 * The NEWEST matching row is the one the caller's send belongs to: an
 * older row with the same text may belong to a send whose `chat:message`
 * has not arrived yet, so retracting it would delete (or mis-index) that
 * send.
 *
 * `lastIndex` re-anchors on the highest surviving row — optimistic rows
 * included, because an optimistic row's index is the last index the
 * client knows about — or `-1` when no row survives. The assistant
 * `streaming`/`partial` placeholders are cleared only when they sit
 * immediately after the removed row, i.e. when they are that send's own.
 */
export function retractOptimisticRow(cache, content) {
  const rows = Array.isArray(cache.messages) ? cache.messages : [];
  let position = -1;
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i].optimistic === true && rows[i].content === content) {
      position = i;
      break;
    }
  }
  if (position === -1) return null;

  const removed = rows[position];
  const messages = rows.filter((_, i) => i !== position);

  let lastIndex = -1;
  for (const m of messages) {
    if (typeof m.index === "number" && m.index > lastIndex) {
      lastIndex = m.index;
    }
  }

  const placeholderIndex = removed.index + 1;
  return {
    messages,
    lastIndex,
    streaming:
      cache.streaming?.messageIndex === placeholderIndex
        ? null
        : cache.streaming,
    partial: cache.partial?.index === placeholderIndex ? null : cache.partial,
  };
}

/**
 * Retract the optimistic row `addUserMessage` inserted for a send the
 * server never accepted, so a phantom bubble is not left behind. A no-op
 * when no matching optimistic row exists (the row was already reconciled
 * with the server's copy, or retracted by `setAgentInbox`).
 */
export function retractUserMessage(set, id, content) {
  set((state) => {
    const cache = state.agentsCache[id];
    if (!cache) return state;
    const retracted = retractOptimisticRow(cache, content);
    if (!retracted) return state;
    return {
      agentsCache: {
        ...state.agentsCache,
        [id]: { ...cache, ...retracted },
      },
    };
  });
}
