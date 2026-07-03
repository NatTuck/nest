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
 *
 * The accumulator's wire format still uses the legacy `content`,
 * `segments: [{type, content}]`, and `currentType` keys. We
 * translate them into the canonical `parts: [{kind, text|thinking}]`
 * and `currentKind` shape that the rest of the store expects.
 */
const normalizeStreaming = (streaming) => {
  if (!streaming) return null;
  const { lastDeltaIndex, ...rest } = streaming;
  const { parts, currentKind } = legacyToParts(rest);
  return {
    ...rest,
    parts,
    currentKind,
    nextDeltaIndex: (lastDeltaIndex ?? -1) + 1,
  };
};

/**
 * Normalize partial message from wire format to internal format (legacy).
 * Wire format uses "charsEnd" to describe position.
 * Internal format uses "charsReceived" to track state, and
 * translates the `content` / `segments: [{type, content}]` /
 * `currentType` keys into the canonical `parts` / `currentKind`.
 *
 * @deprecated Use normalizeStreaming instead
 */
const normalizePartial = (partial) => {
  if (!partial) return null;
  const { charsEnd, ...rest } = partial;
  const { parts, currentKind } = legacyToParts(rest);
  return {
    ...rest,
    parts,
    currentKind,
    charsReceived: charsEnd ?? 0,
  };
};

/**
 * Helper to accumulate a delta into a parts list based on kind.
 *
 * Returns `{ parts, currentKind }`. `parts` is the canonical
 * assistant-message shape: `[{ kind: "text"|"thinking",
 * text|thinking }, ...]`. When the incoming kind matches the
 * trailing part's kind, the text is appended; otherwise a
 * new part is pushed.
 */
const accumulatePart = (parts, _currentKind, content, partType) => {
  const kind = partType || "text";

  if (!Array.isArray(parts) || parts.length === 0) {
    return {
      parts: [newPart(kind, content)],
      currentKind: kind,
    };
  }

  const last = parts[parts.length - 1];
  if (last.kind === kind) {
    const updated = [...parts];
    updated[updated.length - 1] = appendPart(last, content);
    return {
      parts: updated,
      currentKind: kind,
    };
  }

  return {
    parts: [...parts, newPart(kind, content)],
    currentKind: kind,
  };
};

const newPart = (kind, content) => {
  if (kind === "thinking") {
    return { kind: "thinking", thinking: content };
  }
  if (kind === "refusal") {
    return { kind: "refusal", refusal: content };
  }
  if (kind === "tool_use") {
    return {
      kind: "tool_use",
      id: null,
      name: null,
      arguments: null,
      text: content,
    };
  }
  if (kind === "tool_result") {
    return {
      kind: "tool_result",
      toolCallId: null,
      name: null,
      content,
      isError: false,
      text: content,
    };
  }
  if (kind === "tool_arguments") {
    return { kind: "tool_arguments", text: content };
  }
  if (kind === "text") {
    return { kind: "text", text: content };
  }

  return { kind: "text", text: content };
};

const appendPart = (last, content) => {
  if (last.kind === "thinking") {
    return { ...last, thinking: (last.thinking || "") + content };
  }
  if (last.kind === "refusal") {
    return { ...last, refusal: (last.refusal || "") + content };
  }
  return { ...last, text: (last.text || "") + content };
};

// Flatten a streaming/partial parts list to a single string —
// only text parts contribute to visible content; thinking parts
// are returned by `partialThinking` below. Used by the
// overlap-integrity check in `addChatDelta/2`.
const partialPartsToText = (parts) =>
  parts
    .filter((p) => p && p.kind === "text")
    .map((p) => p.text || "")
    .join("");

// Legacy streaming accumulator wire format (kept on the BEAM
// side as `content` + `segments: [{type, content}]` +
// `currentType`) → canonical `parts: [{kind, text|thinking}]`
// + `currentKind`. Returns `{parts: [], currentKind: null}`
// when neither shape is present (e.g. fresh accumulator).
//
// Also tolerates the legacy flat-string `content` shape (still
// seeded in legacy tests) by folding it into a single text
// part.
const legacyToParts = (acc) => {
  if (!acc) return { parts: [], currentKind: null };

  if (Array.isArray(acc.parts)) {
    return {
      parts: acc.parts,
      currentKind: acc.currentKind ?? null,
    };
  }

  if (Array.isArray(acc.segments)) {
    const parts = acc.segments.map((seg) =>
      seg?.type === "thinking"
        ? { kind: "thinking", thinking: seg.content || "" }
        : { kind: "text", text: seg.content || "" },
    );
    return {
      parts,
      currentKind: acc.currentType ?? null,
    };
  }

  if (typeof acc.content === "string" && acc.content.length > 0) {
    return {
      parts: [{ kind: "text", text: acc.content }],
      currentKind: acc.currentType ?? "text",
    };
  }

  return { parts: [], currentKind: null };
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
            { name: agent.name, model: agent.model, status: "idle" },
          ],
        }));
      },

      /**
       * Remove deleted agent
       */
      removeAgent: (name) => {
        set((state) => {
          const newCache = { ...state.agentsCache };
          delete newCache[name];
          return {
            agents: state.agents.filter((a) => a.name !== name),
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
                  parts: [],
                  currentKind: null,
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
          const { parts: newParts, currentKind: newCurrentKind } =
            accumulatePart(
              streaming.parts || [],
              streaming.currentKind,
              content,
              partType,
            );

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

        // Legacy: Support old charsStart/charsEnd protocol with partial
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

        // Migrate a legacy-shaped partial (`content` flat string,
        // no `parts`) on the fly so tests that seed partials in
        // the old shape still work. New code paths always read
        // and write `parts`.
        const existingParts = Array.isArray(partial.parts)
          ? partial.parts
          : partial.content
            ? [{ kind: "text", text: partial.content }]
            : [];
        const existingCurrentKind =
          partial.currentKind ?? (partial.content ? "text" : null);

        // Persist the migration when we encounter a legacy partial
        // so downstream code (and assertions) see the new shape
        // rather than the half-updated shape with both legacy
        // `content` and new `parts` fields.
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

        if (charsStart > currentReceived) {
          return { applied: false, needsSync: true };
        }

        let newContent = content;
        let overlapMismatch = false;
        if (charsStart < currentReceived) {
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

        const { parts: newParts, currentKind: newCurrentKind } = accumulatePart(
          existingParts,
          existingCurrentKind,
          newContent,
          partType,
        );

        const updatedPartial = {
          ...partial,
          // Drop the legacy `content` once we've migrated.
          content: undefined,
          charsReceived: charsEnd,
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
      },

      /**
       * Add complete chat message
       */
      addChatMessage: (id, message) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;

          // Helper: read the message's text via parts first
          // (the canonical wire format), falling back to a flat
          // legacy `content` string.
          const messageText = (m) => {
            if (!m) return "";
            if (Array.isArray(m.parts)) {
              const out = m.parts
                .filter((p) => p && p.kind === "text")
                .map((p) => p.text || "")
                .join("");
              if (out) return out;
            }
            return typeof m.content === "string" ? m.content : "";
          };

          // The streaming accumulator carries `parts` (new format)
          // or `segments` (legacy). Compare via text. Tolerate the
          // older flat `content` shape that's still seeded in
          // tests by routing through `legacyToParts` first.
          const streaming = cache.streaming || cache.partial;
          const streamingIndex = streaming?.messageIndex ?? streaming?.index;
          if (streaming && streamingIndex === message.index) {
            const parts = (streaming.parts ?? []).length
              ? streaming.parts
              : legacyToParts(streaming).parts;
            const streamingContent = partialPartsToText(parts);
            const messageContent = messageText(message);

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

          // First try to find the message by index (the canonical case).
          // If the server echoes at a different index — which happens
          // when the user sends a message in the small window between
          // the `init` event and the `chat:sync` response (the client's
          // `lastIndex` is stale because it doesn't yet know about
          // pre-existing messages) — fall back to a content+recency
          // match against an optimistic message.
          //
          // The race: the client optimistic-adds at `lastIndex + 1`
          // using a stale `lastIndex` (e.g. -1 or a lower value). The
          // server stamps the user message at its authoritative
          // `next_message_index` and broadcasts `chat:message` with
          // the correct index. The index-based de-dup misses, so the
          // server's echo is appended as a new message, leaving the
          // user with two copies of their own message.
          let matchedIndex = cache.messages.findIndex(
            (m) => m.index === message.index,
          );

          if (matchedIndex === -1) {
            // Look for an optimistic message with matching role+content
            // that was created recently (within 30s). The optimistic
            // add stamps `timestamp: new Date().toISOString()`; the
            // server's echo has a different `timestamp`, but the
            // content is the user's input and should match.
            //
            // 30s is deliberately generous — it covers any plausible
            // user typing/clicking window. The only false positive is
            // the user sending the exact same message twice in <30s;
            // in that case the indices get re-bound in order, which
            // matches what the user sees in the UI.
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

          // Derive the legacy `content`/`thinking` fields from
          // `parts` so downstream components that still read those
          // flat fields keep working. `mergedThinking` already
          // does this for the thinking path; the content field
          // here is the visible text (concatenated text parts).
          const mergedThinking = (() => {
            const fromParts = (parts) => {
              if (!Array.isArray(parts)) return null;
              const text = parts
                .filter((p) => p && p.kind === "thinking")
                .map((p) => p.thinking || "")
                .join("");
              return text || null;
            };

            const direct = fromParts(message.parts) ?? message.thinking;
            if (direct) return direct;
            const streamingParts =
              (streaming?.parts ?? []).length > 0
                ? streaming.parts
                : legacyToParts(streaming).parts;
            if (!streamingParts.length) return direct ?? null;
            const fromStreaming = streamingParts
              .filter((p) => p && p.kind === "thinking")
              .map((p) => p.thinking || "")
              .join("");
            if (fromStreaming) {
              console.error(
                "[NEST REGRESSION] Thinking lost on tool-call finalization; " +
                  "fell back to streaming partial. " +
                  "The server's `build_tool_pair/3` is dropping the " +
                  "thinking field again — see llm_runner.ex:274-288. " +
                  "Preserved thinking:",
                fromStreaming,
              );
              return fromStreaming;
            }
            return direct ?? null;
          })();

          // Derive tool calls / results from `parts` (the new
          // wire format). Returns `null` when no relevant parts
          // are present so downstream code can fall through to the
          // legacy `message.toolCalls` / `message.toolResults`
          // fields.
          const toolCallsFromParts = (parts) => {
            if (!Array.isArray(parts)) return null;
            const tcs = parts.filter((p) => p && p.kind === "tool_use");
            if (tcs.length === 0) return null;
            return tcs.map((p) => ({
              id: p.id,
              name: p.name,
              arguments: p.arguments || {},
            }));
          };

          const toolResultsFromParts = (parts) => {
            if (!Array.isArray(parts)) return null;
            const trs = parts.filter((p) => p && p.kind === "tool_result");
            if (trs.length === 0) return null;
            return trs.map((p) => ({
              tool_call_id: p.toolCallId,
              name: p.name,
              content: p.content || "",
              is_error: !!p.isError,
            }));
          };

          // Helper: derive a parts-list view from a message's
          // either-`parts` or legacy-`toolCalls`/`toolResults`
          // fields. Used by the merge path below so messages
          // sent in either shape populate the right `toolCalls`
          // / `toolResults` derivation. Always returns an array
          // (possibly empty).
          const partsShape = (m) => {
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
          };

          // Build the merge-update for a matched message.
          // Used by both the index-match and content-reconcile
          // paths. `m` is the existing cache message (optimistic
          // or already-finalized), `message` is the incoming
          // server echo. We prefer the server's authoritative
          // fields (index, apiLogs, mode-prefixed parts) but
          // preserve user-visible fields from the optimistic
          // add when the server doesn't carry them.
          const buildMerged = (m) => {
            // Merge apiLogs, preferring the new message's apiLogs if they exist
            const mergedApiLogs = message.apiLogs?.length
              ? message.apiLogs
              : m.apiLogs || [];

            // Derive tool calls / results from `parts` (new
            // format) or fall back to legacy fields. Prefer
            // the new message's data; preserve the existing
            // message's data if the new one doesn't carry
            // tool parts.
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
              // Derive the legacy `content` field from
              // `parts` for components that still read it
              // as a flat string. The thinking path
              // (`mergedThinking`) already handles the
              // thinking merge.
              content: messageText(message) || m.content || "",
              thinking: mergedThinking,
              apiLogs: mergedApiLogs,
              toolCalls: mergedToolCalls,
              toolResults: mergedToolResults,
            };
          };

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
                  i === matchedIndex ? buildMerged(m) : m,
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
            parts: [{ kind: "text", text: content }],
            // Flat `content` for components that haven't migrated
            // off the legacy field. The ChatInput mode-prefix
            // stripper and the messageToMarkdown copy path both
            // still read it.
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

          // Legacy partial state for backward compatibility
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
