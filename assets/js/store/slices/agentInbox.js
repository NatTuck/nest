/**
 * Async inbox cache setters.
 *
 * The full queued-message list rides the `chat:inbox` event and the
 * `init` payload; `chat:status` carries only the count (and, separately,
 * the reply debt, which lives on the cache as `owedReplies`). The list
 * holds all four entry kinds: `"agent"` from an `agents-send` or a child
 * agent's completed turn, `"user"` from a human who wrote while the agent
 * was busy, `"query"` from `agents-query`, and `"notice"` from the runtime
 * (a give-up on an unanswered query, or a child that failed, was stopped
 * or produced nothing). Split into its own slice so `agentCache.js` stays
 * under the file-size cap.
 */

import { retractOptimisticRow } from "./agentCacheMessages";

/**
 * Retract the optimistic rows a queued send left behind.
 *
 * `sendMessage` fabricates a user row at `lastIndex + 1` before the
 * push, because the normal case appends the real message at that index.
 * When the push only *queues* the message (the agent was busy) the
 * fabricated index is later occupied by a real row, so the optimistic
 * row must go once `chat:inbox` confirms the message is waiting instead.
 *
 * Each `kind: "user"` entry pairs with the NEWEST still-present
 * `optimistic` row of the same `content` — the entry belongs to the most
 * recent matching send, and an older matching row may belong to a send
 * whose `chat:message` is still in flight — with each row consumed at
 * most once, in list order. Entries this client never sent retract
 * nothing: `agents-send` (`kind: "agent"`), `agents-query`
 * (`kind: "query"`) and runtime notices (`kind: "notice"`).
 *
 * Returns the patch to apply, or `null` when nothing was retracted so
 * the caller can leave `messages`/`lastIndex`/`streaming`/`partial`
 * untouched (the cache object and the inbox list are rebuilt either way).
 */
function retractQueuedOptimistic(cache, list) {
  let current = cache;
  let changed = false;
  for (const entry of list) {
    if (entry?.kind !== "user") continue;
    const retracted = retractOptimisticRow(current, entry.content);
    if (!retracted) continue;
    current = { ...current, ...retracted };
    changed = true;
  }
  if (!changed) return null;
  const { messages, lastIndex, streaming, partial } = current;
  return { messages, lastIndex, streaming, partial };
}

export function agentInboxSetters(set) {
  return {
    setAgentInbox: (id, messages) => {
      const list = Array.isArray(messages) ? messages : [];
      set((state) => {
        const cache = state.agentsCache[id];
        if (!cache) return state;
        const retracted = retractQueuedOptimistic(cache, list);
        return {
          agentsCache: {
            ...state.agentsCache,
            [id]: {
              ...cache,
              ...(retracted ?? {}),
              inbox: list,
              pendingMessageCount: list.length,
            },
          },
        };
      });
    },
  };
}
