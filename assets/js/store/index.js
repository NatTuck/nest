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
  // The current authenticated user, populated by the lobby's
  // `init` payload (`current_user`). Kept on the main store
  // rather than a separate auth slice so a single `_reset()`
  // clears every bit of session state in one place.
  currentUser: null,
  // The caller's invites (active, used, revoked). Populated
  // by the lobby's `init` payload (`invites`) and mutated by
  // `invite:created` / `invite:revoked` pushes.
  invites: [],
  // Inline error from the last invite create/revoke attempt
  // that failed at the server. Cleared on the next attempt.
  invitesError: null,
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

// `accumulatePart` only handles the text/thinking/refusal shapes
// cleanly. Tool-use streaming has a different shape (`{id, name,
// arguments}` per part), so we route tool_use_start and
// tool_use_delta through these dedicated helpers. The Agent
// already resolves `:by_index` ids to concrete strings before
// broadcasting, so the JS never sees `:by_index`.

// Push a new tool_use part onto the parts list. Idempotent
// against a duplicate start (same `id` already present): we
// don't re-push and don't mutate the existing part — the second
// event is treated as a no-op so a retransmitted start doesn't
// lose any arguments the JS has already accumulated.
const applyToolUseStart = (parts, { id, name }) => {
  if (parts.some((p) => p && p.kind === "tool_use" && p.id === id)) {
    return parts;
  }
  return [...parts, { kind: "tool_use", id, name, arguments: "" }];
};

// Route a streaming delta to the right accumulator helper based
// on its `partType`. Returns the updated parts list. Text/
// thinking/refusal and the legacy `tool_use` shape (used by
// older tests) still go through `accumulatePart` so existing
// call paths keep working; the new `tool_use_start` /
// `tool_use_delta` shapes route through the dedicated helpers
// above.
const applyPartDelta = (parts, partType, payload) => {
  if (partType === "tool_use_start") {
    return applyToolUseStart(parts, {
      id: payload.toolCallId,
      name: payload.toolCallName,
    });
  }
  if (partType === "tool_use_delta") {
    return applyToolUseDelta(parts, {
      id: payload.toolCallId,
      argumentsDelta: payload.content || "",
    });
  }
  return parts;
};

// Append an `arguments_delta` fragment to the matching tool_use
// part. Returns the parts list unchanged if no part with the
// given `id` exists yet (the BEAM may emit a delta before the
// matching start — uncommon but possible if the wire reorder
// happens; in that case we drop the fragment and the JS's first
// paint of the tool call just shows the name without arguments).
const applyToolUseDelta = (parts, { id, argumentsDelta }) => {
  let found = false;
  const next = parts.map((p) => {
    if (p && p.kind === "tool_use" && p.id === id) {
      found = true;
      return { ...p, arguments: (p.arguments || "") + argumentsDelta };
    }
    return p;
  });
  return found ? next : parts;
};

// Legacy streaming accumulator wire format (kept on the BEAM
// side as `content` + `segments: [{type, content}]` +
// `currentType`) → canonical `parts: [{kind, text|thinking}]`
// + `currentKind`. Returns `{parts: [], currentKind: null}`
// when neither shape is present (e.g. fresh accumulator).
//
// Also tolerates the legacy flat-string `content` shape (still
// seeded in legacy tests) by folding it into a single text
// part.
//
// In-flight tool calls surface in two places on the wire:
//   - `segments` may carry a `%{type: "tool_use", id}` marker
//     for each in-progress tool call (the same marker that
//     `finalize/1` uses to splice the ToolUse part into the
//     finalized message), AND
//   - `toolCalls` is a list of `{id, name, arguments}`
//     describing every in-flight call — `arguments` is a
//     partial JSON string at this stage (vs. a parsed map in
//     the finalized `chat:message` payload).
//
// When `toolCalls` is present, we use it as the source of
// truth for tool-call parts and skip any `tool_use` markers
// in `segments` (they'd produce empty `tool_use` parts).
// Otherwise we synthesize a `tool_use` part from each marker
// with `arguments: ""` so the renderer at least shows the
// tool name.
const legacyToParts = (acc) => {
  if (!acc) return { parts: [], currentKind: null };

  if (Array.isArray(acc.parts)) {
    return {
      parts: acc.parts,
      currentKind: acc.currentKind ?? null,
    };
  }

  if (Array.isArray(acc.segments) || Array.isArray(acc.toolCalls)) {
    const toolCallById = new Map(
      (acc.toolCalls ?? []).map((tc) => [tc.id, tc]),
    );
    const parts = (acc.segments ?? []).map((seg) => {
      if (seg?.type === "thinking") {
        return { kind: "thinking", thinking: seg.content || "" };
      }
      if (seg?.type === "tool_use") {
        const tc = toolCallById.get(seg.id);
        return {
          kind: "tool_use",
          id: seg.id,
          name: tc?.name ?? "",
          arguments: tc?.arguments ?? "",
        };
      }
      return { kind: "text", text: seg.content || "" };
    });
    // If `toolCalls` had entries that didn't appear in
    // `segments` (defensive — the BEAM emits both), append
    // them at the end so they're not lost.
    const seenIds = new Set(
      parts.filter((p) => p.kind === "tool_use").map((p) => p.id),
    );
    for (const tc of acc.toolCalls ?? []) {
      if (!seenIds.has(tc.id)) {
        parts.push({
          kind: "tool_use",
          id: tc.id,
          name: tc.name ?? "",
          arguments: tc.arguments ?? "",
        });
      }
    }

    // `currentType` from the wire is `{:tool_use, id}` (Elixir
    // tuple → JSON array `["tool_use", "call_abc"]`) for
    // tool-use blocks, or `:text` / `:thinking` (atom →
    // string) for the others. Collapse the array shape to the
    // plain kind string the rest of the store expects.
    const currentKind = Array.isArray(acc.currentType)
      ? (acc.currentType[0] ?? null)
      : (acc.currentType ?? null);

    return {
      parts,
      currentKind,
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
      // Agents whose persisted `model` no longer resolves to a
      // runtime provider. Surfaced in the sidebar as broken
      // entries so the user can pick a replacement model from
      // the ChatPage's :model_missing banner.
      brokenAgents: [],
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
        // We rely on the wire payload carrying the
        // sub-agent fields (`parentId`, `parentName`,
        // `depth`) when they're set. We deliberately do
        // NOT add defaults here so existing tests that
        // assert a minimal agent shape stay accurate.
        set({ agents: agents || [] });
      },

      /**
       * Set models list from lobby init
       */
      setModels: (models) => {
        set({ models });
      },

      /**
       * Set the broken-agents list from the lobby's `init`
       * payload. Agents in this list are still listed in the
       * sidebar (so the user can pick them and repair), but
       * they have `:model_missing` status and a banner in the
       * ChatPage prompts a replacement-model selection.
       */
      setBrokenAgents: (brokenAgents) => {
        set({ brokenAgents: brokenAgents || [] });
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
            {
              name: agent.name,
              model: agent.model,
              status: agent.status || "idle",
              // Sub-agent identity — used to render the agent
              // tree in the Sidebar. Defaults to no parent
              // (root agent).
              parentId: agent.parentId ?? null,
              parentName: agent.parentName ?? null,
              depth: agent.depth ?? 0,
            },
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
            // Same lifecycle for the broken-agents list —
            // the user can no longer repair what's gone.
            brokenAgents: state.brokenAgents.filter((a) => a.name !== name),
          };
        });
      },

      /**
       * Update the model on the agents list AND the per-agent
       * cache when the server broadcasts `agent:updated`
       * (the lobby path for `Agents.change_model/2`). Also
       * drops the agent from the `brokenAgents` payload if
       * it was previously reported as unresolvable.
       *
       * The per-agent `cache.model` is updated so an open
       * ChatPage that has already joined sees the new model
       * header immediately. Same shape as the wire payload:
       * `model = { name: string, provider: string | null }`.
       */
      applyAgentModelUpdate: (name, model) => {
        set((state) => {
          const newAgents = state.agents.map((a) =>
            a.name === name ? { ...a, model, status: "idle" } : a,
          );
          const newCache = state.agentsCache[name]
            ? {
                ...state.agentsCache,
                [name]: { ...state.agentsCache[name], model },
              }
            : state.agentsCache;

          // Drop the agent from `brokenAgents` once a
          // replacement has been picked (we assume the new
          // model resolves — `change_model/2` already
          // validated that server-side, and the server's
          // reply confirms it).
          const newBroken = state.brokenAgents.filter((a) => a.name !== name);

          return {
            agents: newAgents,
            agentsCache: newCache,
            brokenAgents: newBroken,
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
                // Sub-agent identity (used by the Sidebar tree + the
                // "back to parent" link on a child's last message).
                // `null` for roots; the integer `agents.id` and the
                // readable name are both carried so the UI can render
                // a tree without an extra round-trip.
                parentId: payload.parentId ?? existing?.parentId ?? null,
                parentName: payload.parentName ?? existing?.parentName ?? null,
                depth: payload.depth ?? existing?.depth ?? 0,
                // Cumulative usage from all descendants (children,
                // grandchildren, etc.). The chip's three-way
                // display reads these alongside `usage` (direct).
                descendantUsage:
                  payload.descendantUsage ?? existing?.descendantUsage ?? null,
                totalUsage: payload.totalUsage ?? existing?.totalUsage ?? null,
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
       * Clear a chat-task error without re-joining the channel.
       *
       * Called from the StatusBanner's Dismiss button so the user
       * can recover from a chat-task error without a full page
       * reload. Promotes `status` from "error" back to "connected"
       * only when we know the channel is alive (`agentState ===
       * "idle"`, which is the case for chat-task errors on a
       * previously-connected channel). For genuine channel-join
       * failures where `agentState` is null, the user must Retry
       * (which re-joins via `handleRetry -> joinAgent`).
       */
      clearAgentError: (id) => {
        set((state) => {
          const existing = state.agentsCache[id];
          if (!existing) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: {
                ...existing,
                status:
                  existing.agentState === "idle" && existing.status === "error"
                    ? "connected"
                    : existing.status,
                error: null,
              },
            },
          };
        });
      },

      /**
       * Set a compaction-failure error message on the agent cache.
       * The `chat:status` event with `status: "compaction_failed"` sets
       * `agentState`; this stores the user-facing error text so the
       * StatusBanner can show it next to the Retry button.
       */
      setCompactionError: (id, error) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, compactionError: error },
            },
          };
        });
      },

      /**
       * Clear the compaction-error text. Called when the user retries
       * and the agent transitions back to `:compacting` (so the banner
       * text updates to "Compacting..." without the stale error).
       */
      clearCompactionError: (id) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, compactionError: null },
            },
          };
        });
      },

      /**
       * Set a compaction-loop error message on the agent cache.
       * Distinct from `setCompactionError`: this is paired with the
       * `:compaction_loop_detected` agentState, which renders an OK
       * button (not Retry). The StatusBanner reads both fields to
       * render the right banner.
       */
      setCompactionLoop: (id, error) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, compactionLoop: error },
            },
          };
        });
      },

      /**
       * Clear the compaction-loop error text. Called when the user
       * clicks OK (which transitions the agent back to `:idle`), or
       * automatically when the agent leaves the loop state.
       */
      clearCompactionLoop: (id) => {
        set((state) => {
          const cache = state.agentsCache[id];
          if (!cache) return state;
          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, compactionLoop: null },
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

          // When the agent transitions out of `:compaction_failed`
          // (either to `:compacting` for a retry, or to `:idle` /
          // streaming after a successful compaction), clear the stale
          // error text so the banner switches to the right message.
          // Same for `:compaction_loop_detected` — when the user
          // clicks OK, the agent transitions back to `:idle` and the
          // loop-error text goes away.
          const clear_compaction_error =
            agentState !== "compaction_failed" ? { compactionError: null } : {};
          const clear_compaction_loop =
            agentState !== "compaction_loop_detected"
              ? { compactionLoop: null }
              : {};
          const patch = {
            ...clear_compaction_error,
            ...clear_compaction_loop,
          };

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, agentState, ...patch, ...(extra || {}) },
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

          // The marker's `index` is the new partition boundary:
          // everything in the previous `state.chat_state.messages`
          // (with `index <= marker.index`) just moved to
          // `state.chat_state.history`. Drop those rows from
          // `cache.messages` so the same messages don't appear
          // in both the history pane and the active area. The
          // new active messages the server built (fresh_system,
          // summary_user, continuation_tail) are not broadcast
          // individually — the channel's `requestSync` is
          // triggered right after this returns, using
          // `marker.index` as the lower bound, to fetch them.
          const boundary = marker?.index;
          const nextMessages =
            typeof boundary === "number"
              ? cache.messages.filter((m) => m.index > boundary)
              : cache.messages;

          return {
            agentsCache: {
              ...state.agentsCache,
              [id]: { ...cache, history: nextHistory, messages: nextMessages },
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

          // Apply the delta. The new `tool_use_start` /
          // `tool_use_delta` shapes bypass `accumulatePart`
          // (which handles text/thinking/refusal and the legacy
          // `tool_use` / `tool_result` shapes) and route through
          // dedicated helpers so the tool_use part carries
          // proper `id`, `name`, and accumulated `arguments`
          // from the first event onward. The BEAM resolves
          // `:by_index` to a concrete id before broadcasting, so
          // the JS only sees concrete ids.
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

        // Tool-use events ship `charsStart: 0, charsEnd: 0`
        // — the `content` field is the partial-JSON fragment,
        // not a grapheme position in the streamed text.
        // Bypass the charsStart/charsEnd overlap check entirely
        // and let `applyPartDelta` route the event into the
        // tool_use part. Without this, a tool_use_start
        // arriving after any text delta trips the integrity
        // check (its `charsStart: 0` is below the running
        // `charsReceived`) and the event is silently dropped.
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
          : accumulatePart(
              existingParts,
              existingCurrentKind,
              newContent,
              partType,
            );

        const updatedPartial = {
          ...partial,
          // Drop the legacy `content` once we've migrated.
          content: undefined,
          // Only advance `charsReceived` for text/thinking
          // deltas. Tool-use events ship `chars_end: 0`
          // (their payload is the partial-JSON fragment, not
          // a grapheme position in the text buffer), so
          // writing `charsEnd` here would clobber the text
          // position and force every post-tool text delta
          // to trip the integrity check + `needsSync`.
          charsReceived: isToolUseEvent
            ? (partial.charsReceived ?? 0)
            : charsEnd,
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
        // Read the cache via get() up-front so the matchedIndex
        // and lastIndex are visible outside the set callback —
        // needed for the gap-detection return value the
        // channels.js handler reads to decide whether to
        // request a sync.
        const cache = get().agentsCache[id];
        if (!cache) return { applied: false, needsSync: false };

        // Hoisted out of the set callback so the gap-detection
        // return value below can read it.
        let matchedIndex = -1;

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
          matchedIndex = cache.messages.findIndex(
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

            // Prefer the streaming partial when it's strictly longer
            // than the broadcast thinking — defends against a BEAM-
            // side path that abbreviates thinking on tool-call
            // finalization. Broadcast stays authoritative when the
            // two are equal-length or the broadcast is longer, so a
            // legitimate edit on the server side still wins.
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

        // Gap detection: when a `chat:message` arrives from the
        // server with an index higher than the client's
        // `lastIndex + 1` and the message wasn't matched (either
        // by index or by the optimistic-reconcile path), there's
        // a gap in the index sequence — typically because a
        // `chat:message` was silently lost in transit (network
        // blip, server crash before broadcast, PubSub reordering
        // with one event dropped). The `lastIndex >= 0` guard
        // prevents a spurious sync on the very first message
        // (where a gap from -1 is expected, not a real loss).
        // The channels.js handler reads this signal and calls
        // `requestSync` to fill the gap.
        //
        // We also return `snapshotLastIndex` — the pre-update
        // `cache.lastIndex` value — so the channel handler can
        // pass it as the sync's lower bound. The set callback
        // bumps `cache.lastIndex` to `message.index`, but that's
        // the wrong lower bound for filling a gap: it would
        // skip the missing messages. The snapshot value is the
        // highest *complete* index we have, so the sync
        // response carries everything from there onwards.
        const snapshotLastIndex = cache.lastIndex ?? -1;
        const needsSync =
          matchedIndex === -1 &&
          message.index > snapshotLastIndex + 1 &&
          snapshotLastIndex >= 0;

        return { applied: true, needsSync, snapshotLastIndex };
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
       * Set the current user. Called by:
       *  - the lobby's `init` push when the WS handshake
       *    completes (overwrites whatever was here with the
       *    server-authoritative slice).
       *  - tests that need to seed `currentUser` directly.
       */
      setCurrentUser: (user) => {
        set({ currentUser: user });
      },

      /**
       * Set the caller's invites list. Called by the lobby's
       * `init` push to populate the slice on connect, and by
       * tests that need to seed invites directly.
       */
      setInvites: (invites) => {
        set({ invites: invites || [] });
      },

      /**
       * Set (or clear) the inline invite-error message. The
       * channel handlers call this when the server replies
       * `{:error, ...}` to a `create_invite` or `revoke_invite`
       * push; the InvitesPage renders the message above the
       * table. `null` clears it.
       */
      setInvitesError: (error) => {
        set({ invitesError: error });
      },

      /**
       * Reset every piece of session state. The WS is
       * disconnected by the caller before this fires (see
       * `Sidebar`'s `handleLogout`); this is the in-memory
       * counterpart. The `_reset` alias is kept for tests
       * that already call it directly.
       */
      logout: () => {
        set(initialState);
      },

      /**
       * Reset store to initial state (for testing).
       * Same body as `logout` — kept as a separate name so
       * test setup can stay explicit about intent.
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
