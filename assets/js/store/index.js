/**
 * Zustand store for global application state.
 *
 * The store now contains ONLY immutable data.
 * Mutable channel refs are in channels.js.
 * Channel callbacks call these store methods.
 */

import { create } from "zustand";
import { devtools } from "zustand/middleware";
import {
  graphemeCount,
  graphemeLast,
  graphemeSlice,
} from "../utils/grapheme.js";

/**
 * @typedef {Object} AgentCache
 * @property {Array} messages - Complete messages
 * @property {Object|null} partial - Partial streaming message
 * @property {number} lastIndex - Last complete message index
 * @property {'disconnected'|'connecting'|'connected'|'error'} status - Connection status
 * @property {string|null} error - Error message if status is 'error'
 * @property {string|null} model - Agent model name
 */

/**
 * Initial state factory for store reset
 */
const initialState = {
  isConnected: false,
  agents: [],
  models: [],
  vocations: [],
  agentsCache: {},
};

/**
 * Normalize partial message from wire format to internal format.
 * Wire format uses "charsEnd" to describe position.
 * Internal format uses "charsReceived" to track state.
 */
const normalizePartial = (partial) => {
  if (!partial) return null;
  const { charsEnd, ...rest } = partial;
  return { ...rest, charsReceived: charsEnd ?? 0 };
};

/**
 * Helper to accumulate content into segments based on type.
 * Returns updated segments array and current type.
 */
const accumulateSegment = (segments, _currentType, content, partType) => {
  const type = partType || "text";

  if (segments.length === 0) {
    // First segment
    return {
      segments: [{ type, content }],
      currentType: type,
    };
  }

  const lastSegment = segments[segments.length - 1];
  if (lastSegment.type === type) {
    // Continue existing segment
    const updatedSegments = [...segments];
    updatedSegments[updatedSegments.length - 1] = {
      ...lastSegment,
      content: lastSegment.content + content,
    };
    return {
      segments: updatedSegments,
      currentType: type,
    };
  } else {
    // Start new segment
    return {
      segments: [...segments, { type, content }],
      currentType: type,
    };
  }
};

/**
 * Create a Zustand store with devtools in development
 */
export const useStore = create(
  devtools(
    (set, get) => ({
      // Socket connection status (for global indicator)
      isConnected: false,

      // Agents list from lobby
      agents: [],
      models: [],

      /**
       * Agent cache: { [agentId]: AgentCache }
       * Only contains agents we've attempted to join.
       */
      agentsCache: {},

      // Setters called by channels.js

      /**
       * Set socket connection status
       */
      setIsConnected: (connected) => {
        set({ isConnected: connected });
      },

      /**
       * Set agents list from lobby init
       */
      setAgents: (agents) => {
        set({ agents });
      },

      /**
       * Set models list from lobby init
       */
      setModels: (models) => {
        set({ models });
      },

      /**
       * Set vocations list from lobby init
       */
      setVocations: (vocations) => {
        set({ vocations });
      },

      /**
       * Add newly created agent
       */
      addAgent: (agent) => {
        set((state) => ({
          agents: [
            ...state.agents,
            { id: agent.id, model: agent.model, status: "idle" },
          ],
        }));
      },

      /**
       * Remove deleted agent
       */
      removeAgent: (id) => {
        set((state) => {
          const newCache = { ...state.agentsCache };
          delete newCache[id];
          return {
            agents: state.agents.filter((a) => a.id !== id),
            agentsCache: newCache,
          };
        });
      },

      /**
       * Set agent status to connecting (called before join)
       */
      setAgentConnecting: (id) => {
        set((state) => {
          const existing = state.agentsCache[id];
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: existing
                ? { ...existing, status: "connecting", error: null }
                : {
                    messages: [],
                    partial: null,
                    lastIndex: -1,
                    status: "connecting",
                    error: null,
                    model: null,
                  },
            },
          };
        });
      },

      /**
       * Set agent as connected with initial data
       */
      setAgentConnected: (id, payload) => {
        set((state) => {
          const existing = state.agentsCache[id];
          const messages = payload.messages || [];

          const finalMessages =
            existing?.messages?.length > messages.length
              ? existing.messages
              : messages;

          const lastIndex =
            finalMessages.length > 0
              ? Math.max(...finalMessages.map((m) => m.index))
              : -1;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                messages: finalMessages,
                partial: normalizePartial(payload.partial),
                lastIndex,
                status: "connected",
                error: null,
                model: payload.model || existing?.model || null,
              },
            },
          };
        });
      },

      /**
       * Set agent status to disconnected
       */
      setAgentDisconnected: (id) => {
        set((state) => {
          const existing = state.agentsCache[id];
          if (!existing) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...existing, status: "disconnected" },
            },
          };
        });
      },

      /**
       * Set agent status to error
       */
      setAgentError: (id, error) => {
        set((state) => {
          const existing = state.agentsCache[id];
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: existing
                ? { ...existing, status: "error", error }
                : {
                    messages: [],
                    partial: null,
                    lastIndex: -1,
                    status: "error",
                    error,
                    model: null,
                  },
            },
          };
        });
      },

      /**
       * Add chat delta (streaming content)
       * Returns { applied: boolean, needsSync: boolean, overlapMismatch: boolean }
       */
      addChatDelta: (id, payload) => {
        const state = get();
        const cache = state.agentsCache[id];
        if (!cache) return { applied: false, needsSync: false };

        const partial =
          cache.partial && cache.partial.index === payload.index
            ? cache.partial
            : {
                index: payload.index,
                role: "assistant",
                content: "",
                charsReceived: 0,
                segments: [],
                currentType: null,
              };

        const currentReceived = partial.charsReceived || 0;

        if (payload.charsStart > currentReceived) {
          return { applied: false, needsSync: true };
        }

        if (payload.charsStart < currentReceived) {
          const overlap = currentReceived - payload.charsStart;
          const expectedOverlap = graphemeLast(partial.content, overlap);
          const actualOverlap = graphemeSlice(payload.content, 0, overlap);

          const mismatch = expectedOverlap !== actualOverlap;

          if (mismatch) {
            console.warn(`[agent:${id}] Delta overlap mismatch:`, {
              delta: {
                index: payload.index,
                charsStart: payload.charsStart,
                charsEnd: payload.charsEnd,
                content: payload.content,
                graphemeCount: graphemeCount(payload.content),
              },
              partial: {
                index: partial.index,
                charsReceived: currentReceived,
                graphemeCount: graphemeCount(partial.content),
                content:
                  graphemeCount(partial.content) > 100
                    ? `...${graphemeLast(partial.content, 50)}`
                    : partial.content,
              },
              overlapCalc: {
                overlapChars: overlap,
                expected: expectedOverlap,
                actual: actualOverlap,
              },
              integrityCheck: {
                contentVsCharsReceived:
                  graphemeCount(partial.content) === currentReceived
                    ? "OK"
                    : `MISMATCH: graphemeCount=${graphemeCount(partial.content)}, charsReceived=${currentReceived}`,
              },
            });
          }

          const newContent = graphemeSlice(payload.content, overlap);
          if (graphemeCount(newContent) === 0) {
            return {
              applied: false,
              needsSync: false,
              overlapMismatch: mismatch,
            };
          }

          const { segments: newSegments, currentType: newCurrentType } =
            accumulateSegment(
              partial.segments || [],
              partial.currentType,
              newContent,
              payload.partType,
            );

          set((s) => ({
            agentsCache: {
              ...s.agentsCache,
              [id]: {
                ...cache,
                partial: {
                  ...partial,
                  content: partial.content + newContent,
                  charsReceived: payload.charsEnd,
                  segments: newSegments,
                  currentType: newCurrentType,
                },
                waitingForResponse: false,
              },
            },
          }));
          return { applied: true, needsSync: false, overlapMismatch: mismatch };
        }

        const { segments: newSegments, currentType: newCurrentType } =
          accumulateSegment(
            partial.segments || [],
            partial.currentType,
            payload.content,
            payload.partType,
          );

        set((s) => ({
          agentsCache: {
            ...s.agentsCache,
            [id]: {
              ...cache,
              partial: {
                ...partial,
                content: partial.content + payload.content,
                charsReceived: payload.charsEnd,
                segments: newSegments,
                currentType: newCurrentType,
              },
              waitingForResponse: false,
            },
          },
        }));
        return { applied: true, needsSync: false };
      },

      /**
       * Add complete chat message
       */
      addChatMessage: (id, message) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          const partial = cache.partial;
          if (partial && partial.index === message.index) {
            const partialContent = partial.content || "";
            const messageContent = message.content || "";

            if (partialContent !== messageContent) {
              console.warn(
                `[agent:${id}] Final message differs from partial:`,
                {
                  index: message.index,
                  partial: {
                    graphemeCount: graphemeCount(partialContent),
                    charsReceived: partial.charsReceived,
                    content:
                      graphemeCount(partialContent) > 200
                        ? `...${graphemeLast(partialContent, 100)}`
                        : partialContent,
                  },
                  message: {
                    graphemeCount: graphemeCount(messageContent),
                    content:
                      graphemeCount(messageContent) > 200
                        ? `...${graphemeLast(messageContent, 100)}`
                        : messageContent,
                  },
                  diff: {
                    extraInPartial:
                      graphemeCount(partialContent) >
                      graphemeCount(messageContent)
                        ? graphemeSlice(
                            partialContent,
                            graphemeCount(messageContent),
                          )
                        : null,
                    extraInMessage:
                      graphemeCount(messageContent) >
                      graphemeCount(partialContent)
                        ? graphemeSlice(
                            messageContent,
                            graphemeCount(partialContent),
                          )
                        : null,
                    lengthDiff:
                      graphemeCount(partialContent) -
                      graphemeCount(messageContent),
                  },
                },
              );
            }
          }

          const exists = cache.messages.some((m) => m.index === message.index);

          const newMessages = exists
            ? cache.messages.map((m) =>
                m.index === message.index ? message : m,
              )
            : [...cache.messages, message];

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                messages: newMessages,
                partial: null,
                lastIndex: message.index,
              },
            },
          };
        });
      },

      /**
       * Add user message (optimistic)
       */
      addUserMessage: (id, content) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          const newIndex = cache.lastIndex + 1;
          const userMessage = {
            index: newIndex,
            role: "user",
            content,
            timestamp: new Date().toISOString(),
          };

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                messages: [...cache.messages, userMessage],
                lastIndex: newIndex,
                partial: {
                  index: newIndex + 1,
                  role: "assistant",
                  content: "",
                  charsReceived: 0,
                  segments: [],
                  currentType: null,
                },
              },
            },
          };
        });
      },

      /**
       * Clear partial message (on error)
       */
      clearPartial: (id) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, partial: null },
            },
          };
        });
      },

      /**
       * Set waiting for response (user sent message, waiting for assistant)
       */
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

      /**
       * Sync agent messages from server response
       * Merges synced messages into existing cache
       */
      syncAgentMessages: (id, payload) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          const newMessages = payload.messages || [];
          const existingMessages = cache.messages || [];

          // Merge: keep existing, add new ones that don't exist
          const existingIndices = new Set(existingMessages.map((m) => m.index));
          const messagesToAdd = newMessages.filter(
            (m) => !existingIndices.has(m.index),
          );

          const mergedMessages = [...existingMessages, ...messagesToAdd];
          // Sort by index to ensure order
          mergedMessages.sort((a, b) => a.index - b.index);

          const lastIndex =
            mergedMessages.length > 0
              ? Math.max(...mergedMessages.map((m) => m.index))
              : -1;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                messages: mergedMessages,
                partial: normalizePartial(payload.partial),
                status: payload.status || cache.status,
                lastIndex,
              },
            },
          };
        });
      },

      /**
       * Clear all cached messages for an agent
       */
      clearAgentCache: (id) => {
        set((state) => {
          const newCache = { ...state.agentsCache };
          delete newCache[id];
          return { agentsCache: newCache };
        });
      },

      /**
       * Reset store to initial state (for testing)
       */
      _reset: () => {
        set(initialState);
      },
    }),
    { name: "nest-store" },
  ),
);

/**
 * Get initial state (for testing)
 */
export { initialState };
