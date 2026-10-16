/**
 * Async inbox cache setters.
 *
 * The queue is published **incrementally** (issue #27): a `chat:inbox` event
 * carries one delta — `op: "append"`, `"remove"` or `"update"` — with the
 * authoritative `count` after it and the frame's position `inboxSeq` in this
 * agent's stream. The whole list rides only the `init` payload and the
 * `chat:inbox` fetch reply (`op: "replace"`), which is the resync frame.
 * `chat:status` carries only the count (and, separately, the reply debt, which
 * lives on the cache as `owedReplies`). The list holds all four entry kinds:
 * `"agent"` from an `agents-send` or a child agent's completed turn, `"user"`
 * from a human who wrote while the agent was busy, `"query"` from
 * `agents-query`, and `"notice"` from the runtime (a give-up on an unanswered
 * query, or a child that failed, was stopped or produced nothing). Split into
 * its own slice so `agentCache.js` stays under the file-size cap.
 */

import { retractOptimisticRow } from "./agentCacheMessages";

/** The delta ops the wire can carry. Anything else is a contract violation. */
const OPS = new Set(["append", "remove", "update"]);

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

/**
 * Apply one delta to a cached list and return the new list, or `null` when
 * the frame cannot be applied to it.
 *
 * `update` names an entry the client must already hold (the server marks a
 * fetched entry `retrieved` in place), so an unknown id is a gap rather than
 * a no-op. `remove` is tolerant of an unknown id on purpose: the idle
 * delivery path enqueues and consumes in one step, so its removal frame is
 * the first thing a client hears about an entry it never saw appended, and
 * the frame's `count` (checked by the caller) is what proves the result is
 * the server's queue.
 */
function applyDelta(list, payload) {
  if (payload.op === "append" || payload.op === "update") {
    if (!Array.isArray(payload.messages)) return null;
    if (payload.op === "append") return list.concat(payload.messages);

    let next = list;
    for (const entry of payload.messages) {
      const at = next.findIndex((held) => held?.id === entry?.id);
      if (at < 0) return null;
      next = next.map((held, i) => (i === at ? entry : held));
    }
    return next;
  }

  if (!Array.isArray(payload.ids)) return null;
  const gone = new Set(payload.ids);
  return list.filter((held) => !gone.has(held?.id));
}

/**
 * Apply one `chat:inbox` delta to the agent's cached queue, returning
 * `{applied, needsResync}` so the caller can request the full list when the
 * frame did not fit.
 *
 * A frame is applied only when it continues the stream (`inboxSeq` is exactly
 * one past the last applied frame) and leaves the list exactly `count` long —
 * the count is authoritative, so a mismatch means the client's base list was
 * wrong even though the sequence looked contiguous. Anything else (a gap, a
 * sequence that went backwards, which is what an agent restart looks like, a
 * malformed frame, a list that disagrees with the count) is reported as
 * `needsResync`: the client asks for the whole list over `chat:inbox` rather
 * than applying a delta on top of a list it cannot trust. It never guesses.
 */
export function applyAgentInboxDelta(set, get, id, payload) {
  const cache = get().agentsCache[id];
  if (!cache) return { applied: false, needsResync: false };

  const seq = payload?.inboxSeq;
  const count = payload?.count;
  const op = payload?.op;

  if (typeof seq !== "number" || typeof count !== "number" || !OPS.has(op)) {
    console.warn(`[agent:${id}] unusable chat:inbox frame:`, payload);
    return { applied: false, needsResync: true };
  }

  const expected =
    typeof cache.inboxSeq === "number" ? cache.inboxSeq + 1 : null;
  if (expected === null || seq !== expected) {
    console.warn(
      `[agent:${id}] chat:inbox gap: frame ${seq}, expected ${expected ?? "(no baseline)"}. Syncing.`,
    );
    return { applied: false, needsResync: true };
  }

  const list = applyDelta(cache.inbox ?? [], payload);
  if (!list || list.length !== count) {
    console.warn(
      `[agent:${id}] chat:inbox ${op} does not fit: ${list?.length ?? "?"} entries for count ${count}. Syncing.`,
    );
    return { applied: false, needsResync: true };
  }

  // The only frame that can carry a newly queued human message, and so the
  // only one that can have an optimistic row to retract (the full-list path
  // retracts over the whole list).
  const retracted =
    op === "append" ? retractQueuedOptimistic(cache, payload.messages) : null;

  set((state) => {
    const current = state.agentsCache[id];
    if (!current) return state;
    return {
      agentsCache: {
        ...state.agentsCache,
        [id]: {
          ...current,
          ...(retracted ?? {}),
          inbox: list,
          pendingMessageCount: count,
          inboxSeq: seq,
        },
      },
    };
  });

  return { applied: true, needsResync: false };
}

export function agentInboxSetters(set) {
  return {
    /**
     * Replace the cached queue with the full list — the `op: "replace"` frame
     * (`init`, and the reply to a `chat:inbox` fetch). `inboxSeq` is that
     * list's position in the delta stream, and becomes the baseline every
     * later delta is checked against; a payload without one leaves any
     * baseline we already have alone rather than clearing it.
     */
    setAgentInbox: (id, messages, inboxSeq) => {
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
              inboxSeq:
                typeof inboxSeq === "number"
                  ? inboxSeq
                  : (cache.inboxSeq ?? null),
            },
          },
        };
      });
    },
  };
}
