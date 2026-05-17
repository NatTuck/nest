/**
 * Zustand store for global application state.
 *
 * The store now contains ONLY immutable data.
 * Mutable channel refs are in channels.js.
 * Channel callbacks call these store methods.
 */

import { create } from "zustand";
import { devtools } from "zustand/middleware";

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
 * Create a Zustand store with devtools in development
 */
export const useStore = create(
  devtools(
    (set) => ({
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

          // Merge with existing if we have more cached data
          const finalMessages =
            existing?.messages?.length > messages.length
              ? existing.messages
              : messages;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                messages: finalMessages,
                partial: payload.partial || null,
                lastIndex: payload.lastCompleteIndex ?? -1,
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
       */
      addChatDelta: (id, payload) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          const partial = cache.partial || {
            index: payload.index,
            role: "assistant",
            content: "",
            charsReceived: 0,
          };

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                partial: {
                  ...partial,
                  content: partial.content + payload.content,
                  charsReceived: payload.charsEnd,
                },
              },
            },
          };
        });
      },

      /**
       * Add complete chat message
       */
      addChatMessage: (id, message) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

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

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                messages: mergedMessages,
                partial: payload.partial || null,
                status: payload.status || cache.status,
                lastIndex: payload.lastCompleteIndex ?? cache.lastIndex,
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
    }),
    { name: "nest-store" },
  ),
);
