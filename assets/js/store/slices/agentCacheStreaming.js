/**
 * Agent-cache streaming + sync setters for the zustand store.
 * Split from `store/index.js`.
 */

import { normalizePartial, normalizeStreaming } from "../helpers";

export function agentCacheStreamingSetters(set, get) {
  return {
    clearPartial: (id) => {
      const state = get();
      const cache = state.agentsCache[id];
      if (!cache) return;
      set({
        agentsCache: {
          ...state.agentsCache,
          [id]: { ...cache, streaming: null, partial: null },
        },
      });
    },

    clearStreaming: (id) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, streaming: null, partial: null },
          },
        };
      });
    },

    setWaitingForResponse: (id, waiting) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, waitingForResponse: waiting },
          },
        };
      });
    },

    syncAgentMessages: (id, payload) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;

        const newMessages = payload.messages || [];
        const existingMessages = cache.messages || [];
        // The reply is the server's authoritative view of the rows it carries,
        // so a row it re-sends **replaces** the cached copy for that index: a
        // sync exists to repair a cache the client can no longer trust, and
        // letting the cached row win let a phantom survive the very request
        // that should have fixed it. Rows the reply does not carry are kept.
        const byIndex = new Map(newMessages.map((m) => [m.index, m]));
        const existingIndices = new Set(existingMessages.map((m) => m.index));
        const mergedMessages = [
          ...existingMessages.map((m) => byIndex.get(m.index) ?? m),
          ...newMessages.filter((m) => !existingIndices.has(m.index)),
        ];
        mergedMessages.sort((a, b) => a.index - b.index);
        const lastIndex =
          mergedMessages.length > 0
            ? Math.max(...mergedMessages.map((m) => m.index))
            : -1;

        const streaming = payload.streaming
          ? normalizeStreaming(payload.streaming)
          : payload.partial
            ? normalizePartial(payload.partial)
            : null;

        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              ...cache,
              messages: mergedMessages,
              streaming: streaming,
              partial: streaming,
              status: cache.status,
              agentState: payload.status || cache.agentState,
              lastIndex,
              // The count the server reports for the active list, which a
              // `chat:sync` reply carries too. The drain compares the reply's
              // own count against the cache, and `ChatPage` compares this one to
              // tell "still filling" from "genuinely empty".
              messageCount:
                typeof payload.messageCount === "number"
                  ? payload.messageCount
                  : cache.messageCount,
              contextLimit: payload.contextLimit ?? cache.contextLimit,
              contextLimitSource:
                payload.contextLimitSource ?? cache.contextLimitSource,
              usage: payload.usage ?? cache.usage,
            },
          },
        };
      });
    },

    clearAgentCache: (id) => {
      set((state) => {
        const newCache = { ...state.agentsCache };
        delete newCache[id];
        return { agentsCache: newCache };
      });
    },
  };
}
