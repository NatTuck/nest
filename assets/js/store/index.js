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
 * @property {Object|null} streaming - Streaming message state
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
 * Normalize streaming state from wire format to internal format.
 * Wire format uses "lastDeltaIndex" to describe position.
 * Internal format uses "nextDeltaIndex" to track expected next delta.
 */
const normalizeStreaming = (streaming) => {
  if (!streaming) return null;
  const { lastDeltaIndex, ...rest } = streaming;
  return { ...rest, nextDeltaIndex: (lastDeltaIndex ?? -1) + 1 };
};

/**
 * Normalize partial message from wire format to internal format (legacy).
 * Wire format uses "charsEnd" to describe position.
 * Internal format uses "charsReceived" to track state.
 * @deprecated Use normalizeStreaming instead
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
                    streaming: null,
                    partial: null,
                    lastIndex: -1,
                    status: "connecting",
                    error: null,
                    model: null,
                    waitingForResponse: false,
                    contextLimit: null,
                    contextLimitSource: null,
                    usage: null,
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

          // Support both new streaming format and legacy partial format
          const streaming = payload.streaming
            ? normalizeStreaming(payload.streaming)
            : payload.partial
              ? normalizePartial(payload.partial)
              : null;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                messages: finalMessages,
                history: payload.history ?? existing?.history ?? [],
                streaming: streaming,
                partial: streaming, // Keep partial for backward compat
                lastIndex,
                status: "connected",
                agentState: payload.status || "idle",
                error: null,
                model: payload.model || existing?.model || null,
                vocation: payload.vocation || existing?.vocation || null,
                // Persist mode metadata from the init payload so the
                // ChatPage can render the mode selector. Fall back to
                // existing cache values on mid-stream rejoins (where
                // the chat:status response may not include modes).
                modes: payload.modes ?? existing?.modes ?? null,
                defaultMode:
                  payload.defaultMode ?? existing?.defaultMode ?? null,
                currentMode:
                  payload.currentMode ?? existing?.currentMode ?? null,
                // Context-window limit + how it was discovered. Backend
                // may set :config (read from config.toml), :vllm,
                // :openrouter, :llama_cpp (probed from /models), or
                // :default (128k fallback). The chip only uses the
                // number; the source is for debugging / future UI.
                contextLimit:
                  payload.contextLimit ?? existing?.contextLimit ?? null,
                contextLimitSource:
                  payload.contextLimitSource ??
                  existing?.contextLimitSource ??
                  null,
                // Running token totals from the backend. `prompt_tokens`
                // (overwritten per LLM call) drives the chip numerator;
                // the rest are session-wide sums.
                usage: payload.usage ?? existing?.usage ?? null,
                waitingForResponse: false,
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
                    streaming: null,
                    partial: null,
                    lastIndex: -1,
                    status: "error",
                    error,
                    model: null,
                    contextLimit: null,
                    contextLimitSource: null,
                    usage: null,
                  },
            },
          };
        });
      },

      /**
       * Set agent's GenServer state (idle, streaming, executing_tools).
       * Optionally updates the resolved context-window limit and its
       * source in the same write — used by the chat:status handler
       * when the backend sends back a freshly discovered limit.
       */
      setAgentState: (id, agentState, extra) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, agentState, ...(extra || {}) },
            },
          };
        });
      },

      /**
       * Update only the context-window limit (and optional source)
       * for an agent. No-op if the agent isn't in the cache.
       */
      setAgentContextLimit: (id, contextLimit, contextLimitSource) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...cache,
                contextLimit:
                  contextLimit !== undefined
                    ? contextLimit
                    : cache.contextLimit,
                contextLimitSource:
                  contextLimitSource !== undefined
                    ? contextLimitSource
                    : cache.contextLimitSource,
              },
            },
          };
        });
      },

      /**
       * Update the running token-usage totals for an agent. No-op if
       * the agent isn't in the cache, or if `usage` is nullish.
       */
      setAgentUsage: (id, usage) => {
        if (usage == null) return;
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, usage },
            },
          };
        });
      },

      /**
       * Replace the agent's archived history with the new list sent
       * by the backend's chat:compaction event. The store keeps the
       * active `messages` list untouched (the backend has already
       * truncated state.messages to the compacted form) and
       * re-keys `history` with the new array.
       *
       * The marker from the broadcast is appended to history so
       * the UI can render a divider at the boundary.
       */
      setAgentHistory: (id, history, marker) => {
        if (!Array.isArray(history)) return;
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          // The backend may have broadcast the marker separately
          // (e.g. for a UI notification) or as the tail of the
          // history array. Prefer the explicit `marker` argument
          // when present so the caller controls placement.
          const nextHistory =
            marker && !history.some((m) => m.role === "compaction")
              ? [...history, marker]
              : history;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, history: nextHistory },
            },
          };
        });
      },

      /**
       * Set a notification banner for the agent
       */
      setNotification: (id, notification) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, notification },
            },
          };
        });
      },

      /**
       * Clear the notification banner for the agent
       */
      clearNotification: (id) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, notification: null },
            },
          };
        });
      },

      /**
       * Add chat delta (streaming content)
       * Returns { applied: boolean, needsSync: boolean, outOfOrder: boolean }
       *
       * With deltaIndex-based protocol:
       * - Each message has sequential delta indices (0, 1, 2...)
       * - Client expects deltas in order
       * - If deltaIndex doesn't match nextDeltaIndex, it's an error
       */
      addChatDelta: (id, payload) => {
        const state = get();
        const cache = state.agentsCache[id];
        if (!cache) return { applied: false, needsSync: false };

        // Support both new format (messageIndex, deltaIndex) and old format (index, charsStart, charsEnd)
        const messageIndex = payload.messageIndex ?? payload.index;
        const deltaIndex = payload.deltaIndex;
        const charsStart = payload.charsStart;
        const charsEnd = payload.charsEnd;
        const content = payload.content;
        const partType = payload.partType;

        // If using new deltaIndex protocol
        if (deltaIndex !== undefined) {
          const streaming =
            cache.streaming && cache.streaming.messageIndex === messageIndex
              ? cache.streaming
              : {
                  messageIndex: messageIndex,
                  nextDeltaIndex: 0,
                  content: "",
                  segments: [],
                  currentType: null,
                };

          // Check if this is the expected delta
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

          // Apply the delta
          const { segments: newSegments, currentType: newCurrentType } =
            accumulateSegment(
              streaming.segments || [],
              streaming.currentType,
              content,
              partType,
            );

          // Thinking deltas update `segments` (so the ThinkingBlock
          // can render them via `thinkingFor(message)`) but NOT
          // `content` (which `<MessageContent>` renders as visible
          // text). Without this split, thinking text appears twice:
          // once in the yellow box and again as regular markdown
          // below it, then vanishes on finalization when the
          // assistant message's `content` is rebuilt as text-only.
          const newContent =
            partType === "thinking"
              ? streaming.content
              : streaming.content + content;

          set((s) => ({
            agentsCache: {
              ...s.agentsCache,
              [id]: {
                ...cache,
                streaming: {
                  ...streaming,
                  content: newContent,
                  nextDeltaIndex: deltaIndex + 1,
                  segments: newSegments,
                  currentType: newCurrentType,
                  toolCallId: payload.toolCallId || streaming.toolCallId,
                  toolCallName: payload.toolCallName || streaming.toolCallName,
                },
                waitingForResponse: false,
              },
            },
          }));
          return { applied: true, needsSync: false };
        }

        // Legacy: Support old charsStart/charsEnd protocol with partial
        const partial =
          cache.partial && cache.partial.index === messageIndex
            ? cache.partial
            : {
                index: messageIndex,
                role: "assistant",
                content: "",
                charsReceived: 0,
                segments: [],
                currentType: null,
              };

        const currentReceived = partial.charsReceived || 0;

        if (charsStart > currentReceived) {
          return { applied: false, needsSync: true };
        }

        let newContent = content;
        let overlapMismatch = false;
        if (charsStart < currentReceived) {
          const overlap = currentReceived - charsStart;
          const expectedOverlap = graphemeLast(partial.content, overlap);
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

          newContent = graphemeSlice(content, overlap);
          if (graphemeCount(newContent) === 0) {
            return { applied: false, needsSync: false, overlapMismatch };
          }
        }

        const { segments: newSegments, currentType: newCurrentType } =
          accumulateSegment(
            partial.segments || [],
            partial.currentType,
            newContent,
            partType,
          );

        // Thinking deltas update `segments` (for ThinkingBlock) but
        // NOT `content` (which `<MessageContent>` renders as visible
        // text). See the matching comment in the new-protocol branch
        // above for the full rationale.
        const updatedContent =
          partType === "thinking"
            ? partial.content
            : partial.content + newContent;

        set((s) => ({
          agentsCache: {
            ...s.agentsCache,
            [id]: {
              ...cache,
              partial: {
                ...partial,
                content: updatedContent,
                charsReceived: charsEnd,
                segments: newSegments,
                currentType: newCurrentType,
              },
              streaming: {
                ...partial,
                content: updatedContent,
                charsReceived: charsEnd,
                segments: newSegments,
                currentType: newCurrentType,
              },
              waitingForResponse: false,
            },
          },
        }));
        return { applied: true, needsSync: false, overlapMismatch };
      },

      /**
       * Add complete chat message
       */
      addChatMessage: (id, message) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          // Check both streaming (new) and partial (legacy) for backward compatibility
          const streaming = cache.streaming || cache.partial;
          const streamingIndex = streaming?.messageIndex ?? streaming?.index;
          if (streaming && streamingIndex === message.index) {
            const streamingContent = streaming.content || "";
            const messageContent = message.content || "";

            if (streamingContent !== messageContent) {
              const extraInPartial =
                graphemeCount(streamingContent) > graphemeCount(messageContent)
                  ? graphemeSlice(
                      streamingContent,
                      graphemeCount(messageContent),
                    )
                  : null;
              const extraInMessage =
                graphemeCount(messageContent) > graphemeCount(streamingContent)
                  ? graphemeSlice(
                      messageContent,
                      graphemeCount(streamingContent),
                    )
                  : null;

              console.warn(
                `[agent:${id}] Final message differs from partial:`,
                {
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
                      graphemeCount(streamingContent) -
                      graphemeCount(messageContent),
                  },
                },
              );
            }
          }

          const exists = cache.messages.some((m) => m.index === message.index);

          // Merge apiLogs, toolCalls, and toolResults if updating an existing message
          const newMessages = exists
            ? cache.messages.map((m) => {
                if (m.index === message.index) {
                  // Merge apiLogs, preferring the new message's apiLogs if they exist
                  const mergedApiLogs = message.apiLogs?.length
                    ? message.apiLogs
                    : m.apiLogs || [];
                  // Preserve toolCalls and toolResults from existing message if not in new message
                  const mergedToolCalls = message.toolCalls?.length
                    ? message.toolCalls
                    : m.toolCalls || [];
                  const mergedToolResults = message.toolResults?.length
                    ? message.toolResults
                    : m.toolResults || [];
                  return {
                    ...message,
                    apiLogs: mergedApiLogs,
                    toolCalls: mergedToolCalls,
                    toolResults: mergedToolResults,
                  };
                }
                return m;
              })
            : [...cache.messages, message];

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
      },

      /**
       * Add user message (optimistic)
       */
      addUserMessage: (id, content, mode) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          const newIndex = cache.lastIndex + 1;
          const userMessage = {
            index: newIndex,
            role: "user",
            content,
            mode,
            timestamp: new Date().toISOString(),
          };

          const streamingState = {
            messageIndex: newIndex + 1,
            role: "assistant",
            content: "",
            nextDeltaIndex: 0,
            segments: [],
            currentType: null,
          };

          // Legacy partial state for backward compatibility
          const partialState = {
            index: newIndex + 1,
            role: "assistant",
            content: "",
            charsReceived: 0,
            segments: [],
            currentType: null,
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
      },

      /**
       * Clear streaming state (on error)
       * @deprecated Use clearStreaming instead
       */
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

      /**
       * Clear streaming state (on error)
       */
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

          // Support both new streaming format and legacy partial format
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
                // Carry over usage / contextLimit fields if a sync
                // payload ever includes them; otherwise preserve
                // whatever the cache already has.
                contextLimit: payload.contextLimit ?? cache.contextLimit,
                contextLimitSource:
                  payload.contextLimitSource ?? cache.contextLimitSource,
                usage: payload.usage ?? cache.usage,
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
