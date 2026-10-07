/**
 * Agent-cache setters for the zustand store: connection state, error
 * handling, compaction banners, context limit, usage, history, and
 * notifications. Split from `store/index.js`.
 */

import { normalizePartial, normalizeStreaming } from "../helpers";

/**
 * Cap on the number of per-agent caches kept in memory. The message
 * list is immutable and reused across agent switches, so the most
 * recently viewed lists stay cached and the rest are dropped.
 */
export const MAX_CACHED_AGENTS = 12;

// Monotonic recency clock for the LRU eviction below. Not `Date.now()`
// so two joins in the same millisecond still order deterministically.
let viewClock = 0;

/**
 * Whether an entry is protected from eviction. Only `connecting` and
 * `connected` entries are protected — a live channel would keep pushing
 * into a cache that no longer exists. Every other status, including
 * `error`, is evictable.
 */
function isLiveCache(cache) {
  return cache.status === "connecting" || cache.status === "connected";
}

/**
 * Drop the client-only `optimistic` marker from a cached message row.
 * Applied to the rows a join keeps: the server has just told us its
 * state, so a row we still hold is either a real message or a send whose
 * rejection we already surfaced, and it must not be retractable as a
 * queued echo later.
 */
function withoutOptimistic(message) {
  if (!message.optimistic) return message;
  const copy = { ...message };
  delete copy.optimistic;
  return copy;
}

/**
 * Drop the least-recently-viewed agent caches once `agentsCache`
 * exceeds `MAX_CACHED_AGENTS`, mutating the passed copy. The agent
 * being joined and any protected (connecting/connected) entry are
 * skipped.
 */
function evictStaleAgentCaches(agentsCache, currentId) {
  const overflow = Object.keys(agentsCache).length - MAX_CACHED_AGENTS;
  if (overflow <= 0) return;

  const evictable = Object.keys(agentsCache)
    .filter((id) => id !== currentId && !isLiveCache(agentsCache[id]))
    .sort(
      (a, b) =>
        (agentsCache[a].lastViewedAt ?? 0) - (agentsCache[b].lastViewedAt ?? 0),
    );

  for (const id of evictable.slice(0, overflow)) {
    delete agentsCache[id];
  }
}

export function agentCacheSetters(set) {
  return {
    setAgentConnecting: (id) => {
      set((state) => {
        const existing = state.agentsCache[id];
        const lastViewedAt = ++viewClock;
        const agentsCache = {
          ...state.agentsCache,
          [id]: existing
            ? { ...existing, status: "connecting", error: null, lastViewedAt }
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
                lastViewedAt,
              },
        };
        evictStaleAgentCaches(agentsCache, id);
        return { agentsCache };
      });
    },

    setAgentConnected: (id, payload) => {
      set((state) => {
        const existing = state.agentsCache[id];
        const messages = payload.messages || [];
        const kept =
          existing?.messages?.length > messages.length
            ? existing.messages
            : messages;
        // A reconnect confirms the server's state, so any `optimistic`
        // echo we are still holding stops being retractable.
        const finalMessages = kept.some((m) => m.optimistic)
          ? kept.map(withoutOptimistic)
          : kept;
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
        // Both production callers (`init` and `chat:status`) always send
        // both fields, so the `?? existing` fallback only applies to
        // payloads that omit them (e.g. test fixtures).
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
              lastViewedAt: existing?.lastViewedAt ?? 0,
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
              inbox: payload.inbox ?? existing?.inbox ?? [],
              pendingMessageCount:
                payload.pendingMessageCount ??
                existing?.pendingMessageCount ??
                (payload.inbox ?? existing?.inbox ?? []).length,
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

    /**
     * Drop the cached active messages so the next `chat:sync` rebuilds
     * them from `-1`. Unlike `resetAgentConversation`, connection state
     * and status are left intact — used when the client cache is known
     * to disagree with the server: a `messageCount` below the cache
     * (phantom rows), a non-contiguous cache, a compaction we missed
     * while away, or a `needs_repair` reload while the channel is still
     * joined.
     */
    resetAgentMessages: (id) => {
      set((state) => {
        const existing = state.agentsCache[id];
        if (!existing) return state;
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              ...existing,
              messages: [],
              lastIndex: -1,
              partial: null,
              streaming: null,
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
