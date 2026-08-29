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
        const existingIndices = new Set(existingMessages.map((m) => m.index));
        const messagesToAdd = newMessages.filter(
          (m) => !existingIndices.has(m.index),
        );
        const mergedMessages = [...existingMessages, ...messagesToAdd];
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
              history: payload.history ?? cache.history ?? [],
              streaming: streaming,
              partial: streaming,
              status: cache.status,
              agentState: payload.status || cache.agentState,
              lastIndex,
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
