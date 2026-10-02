/**
 * Agent-cache setters for the zustand store: connection state, error
 * handling, compaction banners, context limit, usage, history, and
 * notifications. Split from `store/index.js`.
 */

import { normalizePartial, normalizeStreaming } from "../helpers";

export function agentCacheSetters(set) {
  return {
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
                  history: [],
                  historyPrompts: [],
                  historyError: null,
                  lastCompactionMarker: null,
                  lastCompactionIndex: -1,
                  compactionCount: 0,
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
        const streaming = payload.streaming
          ? normalizeStreaming(payload.streaming)
          : payload.partial
            ? normalizePartial(payload.partial)
            : null;
        // The archive projections are keyed to a compaction count: a
        // higher count means the agent compacted while we were away, so
        // the cached slice/prompts/marker describe a boundary that no
        // longer exists. Drop them and let the channel refetch.
        // `chat:status` (the rejoin path) carries neither field, so the
        // `?? existing` fallback is what preserves them across a plain
        // reconnect.
        const lastCompactionIndex =
          payload.lastCompactionIndex ?? existing?.lastCompactionIndex ?? -1;
        const compactionCount =
          payload.compactionCount ?? existing?.compactionCount ?? 0;
        const archiveStale =
          existing != null && existing.compactionCount !== compactionCount;

        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              messages: finalMessages,
              history: archiveStale ? [] : (existing?.history ?? []),
              historyPrompts: archiveStale
                ? []
                : (existing?.historyPrompts ?? []),
              historyError: archiveStale
                ? null
                : (existing?.historyError ?? null),
              lastCompactionMarker: archiveStale
                ? null
                : (existing?.lastCompactionMarker ?? null),
              lastCompactionIndex,
              compactionCount,
              streaming: streaming,
              partial: streaming,
              lastIndex,
              status: "connected",
              agentState: payload.status || "idle",
              error: null,
              model: payload.model || existing?.model || null,
              vocation: payload.vocation || existing?.vocation || null,
              modes: payload.modes ?? existing?.modes ?? null,
              defaultMode: payload.defaultMode ?? existing?.defaultMode ?? null,
              currentMode: payload.currentMode ?? existing?.currentMode ?? null,
              contextLimit:
                payload.contextLimit ?? existing?.contextLimit ?? null,
              contextLimitSource:
                payload.contextLimitSource ??
                existing?.contextLimitSource ??
                null,
              usage: payload.usage ?? existing?.usage ?? null,
              workspace_path:
                payload.workspace_path ?? existing?.workspace_path ?? null,
              parentId: payload.parentId ?? existing?.parentId ?? null,
              parentName: payload.parentName ?? existing?.parentName ?? null,
              depth: payload.depth ?? existing?.depth ?? 0,
              descendantUsage:
                payload.descendantUsage ?? existing?.descendantUsage ?? null,
              totalUsage: payload.totalUsage ?? existing?.totalUsage ?? null,
              jobs: payload.shellJobs ?? existing?.jobs ?? [],
              waitingForResponse: false,
            },
          },
        };
      });
    },

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
     * Drop the cached conversation for an agent and mark it
     * reconnecting. Used by the `:needs_repair` "Reload agent" flow so
     * the restarted agent's `init` triggers a full `chat:sync` from
     * index -1 (the repaired rows may have shifted indices, so a
     * lastIndex-based incremental sync would miss them).
     */
    resetAgentConversation: (id) => {
      set((state) => {
        const existing = state.agentsCache[id];
        if (!existing) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              ...existing,
              messages: [],
              history: [],
              historyPrompts: [],
              historyError: null,
              lastCompactionMarker: null,
              lastCompactionIndex: -1,
              compactionCount: 0,
              lastIndex: -1,
              partial: null,
              streaming: null,
              status: "connecting",
              error: null,
              agentState: "idle",
              sequenceViolations: null,
              repairCommand: null,
            },
          },
        };
      });
    },

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
                  history: [],
                  historyPrompts: [],
                  historyError: null,
                  lastCompactionMarker: null,
                  lastCompactionIndex: -1,
                  compactionCount: 0,
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

    setCompactionLoop: (id, loopInfo) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, compactionLoop: loopInfo },
          },
        };
      });
    },

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

    setAgentState: (id, agentState, extra) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        const clear_compaction_error =
          agentState !== "compaction_failed" ? { compactionError: null } : {};
        const clear_compaction_loop =
          agentState !== "compaction_loop_detected"
            ? { compactionLoop: null }
            : {};
        const patch = { ...clear_compaction_error, ...clear_compaction_loop };
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, agentState, ...patch, ...(extra || {}) },
          },
        };
      });
    },

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
                contextLimit !== undefined ? contextLimit : cache.contextLimit,
              contextLimitSource:
                contextLimitSource !== undefined
                  ? contextLimitSource
                  : cache.contextLimitSource,
            },
          },
        };
      });
    },

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
     * Apply a `chat:compaction` marker. The archive is not shipped with
     * the broadcast, so any cached slice / prompt list / marker now
     * describes the pre-compaction boundary: clear them and let the
     * channel refetch. Keeps the active list from the post-swap
     * boundary (everything at or below `marker.index` was archived).
     */
    setAgentCompaction: (id, marker) => {
      if (!marker) return;
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        const boundary = marker.index;
        const nextMessages =
          typeof boundary === "number"
            ? cache.messages.filter((m) => m.index > boundary)
            : cache.messages;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              ...cache,
              messages: nextMessages,
              history: [],
              historyPrompts: [],
              historyError: null,
              lastCompactionMarker: null,
              lastCompactionIndex:
                typeof boundary === "number"
                  ? boundary
                  : (cache.lastCompactionIndex ?? -1),
              compactionCount: marker.compactionCount ?? cache.compactionCount,
            },
          },
        };
      });
    },

    setAgentCompactionMarker: (id, marker) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, lastCompactionMarker: marker ?? null },
          },
        };
      });
    },

    /**
     * Merge a page of archived rows into the cache, deduping by index
     * and keeping ascending order. Pages arrive newest-first (the
     * client pages back with `before`), so a plain concat would leave
     * the "Load older" boundary wrong.
     */
    setAgentHistorySlice: (id, rows) => {
      if (!Array.isArray(rows)) return;
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        const byIndex = new Map();
        for (const row of [...(cache.history ?? []), ...rows]) {
          if (row && typeof row.index === "number") byIndex.set(row.index, row);
        }
        const history = [...byIndex.values()].sort((a, b) => a.index - b.index);
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, history, historyError: null },
          },
        };
      });
    },

    /**
     * Record a failed `chat:history` fetch so the expanded card can show
     * an explicit error instead of an endless "Loading…" placeholder.
     */
    setAgentHistoryError: (id, error) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, historyError: error ?? null },
          },
        };
      });
    },

    setAgentHistoryPrompts: (id, rows) => {
      if (!Array.isArray(rows)) return;
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, historyPrompts: rows },
          },
        };
      });
    },

    /**
     * Replace the agent's background shell-job list (pushed as
     * `shell:jobs` from the channel, or read from the join payload).
     */
    setAgentJobs: (id, jobs) => {
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: { ...cache, jobs: jobs ?? [] },
          },
        };
      });
    },

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
  };
}
