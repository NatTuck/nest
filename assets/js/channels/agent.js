/**
 * Agent-channel functions: joining/leaving an agent channel and the
 * chat actions (send/stop/retry/loop-ok). Split from `channels.js` to
 * keep that file under the source-line cap.
 */

import { agentChannels, getStore, joinFailedAgents, socket } from "./state";
import { errorText } from "../utils/errorText";

/**
 * Extract the optional fields a `chat:status` / `init` payload carries
 * beyond the status itself, so `setAgentState` can merge them. Shared
 * by both handlers so a fresh join and a live status push agree.
 */
function statusExtras(payload) {
  const extra = {};

  if (payload.contextLimit !== undefined) {
    extra.contextLimit = payload.contextLimit;
  }
  if (payload.contextLimitSource !== undefined) {
    extra.contextLimitSource = payload.contextLimitSource;
  }
  if (payload.currentMode !== undefined) {
    extra.currentMode = payload.currentMode;
  }
  if (payload.usage !== undefined) {
    extra.usage = payload.usage;
  }
  if (payload.parentId !== undefined) {
    extra.parentId = payload.parentId;
  }
  if (payload.parentName !== undefined) {
    extra.parentName = payload.parentName;
  }
  if (payload.depth !== undefined) {
    extra.depth = payload.depth;
  }
  if (payload.descendantUsage !== undefined) {
    extra.descendantUsage = payload.descendantUsage;
  }
  if (payload.totalUsage !== undefined) {
    extra.totalUsage = payload.totalUsage;
  }
  if (payload.sequenceViolations !== undefined) {
    extra.sequenceViolations = payload.sequenceViolations;
  }
  if (payload.repairCommand !== undefined) {
    extra.repairCommand = payload.repairCommand;
  }
  if (payload.lastCompactionIndex !== undefined) {
    extra.lastCompactionIndex = payload.lastCompactionIndex;
  }
  if (payload.compactionCount !== undefined) {
    extra.compactionCount = payload.compactionCount;
  }
  // The queued-message count rides `chat:status` too, so a missed
  // `chat:inbox` broadcast does not leave the panel's count stale.
  if (payload.pendingMessageCount !== undefined) {
    extra.pendingMessageCount = payload.pendingMessageCount;
  }
  // The peers this agent still owes a reply (`agents-query`). Assigned
  // unconditionally, matching the store: the wire always carries the key
  // (an empty list when nothing is owed), so a payload that omits it
  // becomes `null` — which the inbox panel renders as a missing value —
  // rather than silently keeping a debt this payload did not confirm.
  extra.owedReplies = payload.owedReplies ?? null;

  return extra;
}

/**
 * Whether the cached messages form a contiguous ascending run
 * (`messages[i].index === messages[i-1].index + 1`). A contiguous run
 * makes `lastIndex` (the max index) a safe watermark: a lastIndex-based
 * sync resumes from it without leaving a hole behind, so the cached
 * rows can be trusted. A gap means a missing middle row would never be
 * filled by a lastIndex-based sync.
 */
function isContiguous(messages) {
  for (let i = 1; i < messages.length; i++) {
    if (messages[i].index !== messages[i - 1].index + 1) return false;
  }
  return true;
}

/**
 * Reconcile the cache with a fresh `init` / `chat:status` payload.
 *
 * The active list is immutable, so a cache that still lines up with the
 * server is kept and only the delta is fetched. The cases, in order:
 *
 *   1. `needs_repair` — the client cache can't be trusted at all; reset
 *      and rebuild from `-1`.
 *   2. a `lastCompactionIndex` at or above the cached `lastIndex`, or one
 *      that differs from `priorBoundary` (the boundary the cache was built
 *      around, captured before `setAgentConnected` overwrote it) — a missed
 *      compaction archived part of the cached active list. Checked before
 *      the count-equality check because a post-compaction active count can
 *      coincidentally match a stale pre-compaction cache. The `differs`
 *      check catches a compaction whose boundary sits below a drifted
 *      cached tail, where `>=` alone would miss it.
 *   3. an equal `messageCount` — nothing to do.
 *   4. a smaller `messageCount` — the client is ahead (a phantom row the
 *      DB never committed); reset and rebuild from `-1`.
 *   5. a larger `messageCount` over a contiguous cached run — keep the
 *      cache and request the delta from `cache.lastIndex`.
 *   6. anything else (non-contiguous cache) — reset and rebuild from
 *      `-1`.
 */
function reconcileAgentCache(store, agentId, payload, priorBoundary = -1) {
  if (payload.status === "needs_repair") {
    store.resetAgentMessages(agentId);
    store.setAgentState(agentId, "needs_repair", statusExtras(payload));
    requestSync(agentId, { lastIndex: -1 });
    return;
  }

  const cache = getStore().agentsCache[agentId];
  const messages = cache?.messages ?? [];
  const lastIndex = cache?.lastIndex ?? -1;

  // A boundary at or above the cached tail means every cached row was
  // archived. `===` must reset too: a boundary landing exactly on the
  // cached tail archives the whole cached list. A boundary that moved
  // from the one the cache was built around also invalidates it: the
  // cached tail can sit above the new boundary, so `>=` alone misses it.
  if (
    typeof payload.lastCompactionIndex === "number" &&
    (payload.lastCompactionIndex >= lastIndex ||
      payload.lastCompactionIndex !== priorBoundary)
  ) {
    store.resetAgentMessages(agentId);
    requestSync(agentId, { lastIndex: -1 });
    return;
  }

  if (typeof payload.messageCount !== "number") return;
  if (payload.messageCount === messages.length) return;

  if (payload.messageCount < messages.length || !isContiguous(messages)) {
    store.resetAgentMessages(agentId);
    requestSync(agentId, { lastIndex: -1 });
    return;
  }

  requestSync(agentId);
}

/**
 * Request a `chat:sync` for the agent. Pushes the request
 * and updates the cache from the response. Multiple
 * overlapping calls fire multiple pushes (the response
 * merge is idempotent).
 *
 * Callers may pass `{lastIndex: number}` to override the
 * lower bound. The chat:compaction handler passes
 * `marker.index`, the archived boundary: every row at or below
 * it moved into the archive, so the first row of the post-swap
 * active list is `marker.index + 1`. When `lastIndex` is
 * omitted, the agent's `cache.lastIndex` is used.
 */
function requestSync(agentId, opts = {}) {
  const cache = getStore().agentsCache[agentId];
  if (!cache) return;

  const lastIndex =
    typeof opts.lastIndex === "number"
      ? opts.lastIndex
      : (cache.lastIndex ?? -1);

  const channel = agentChannels.get(agentId);
  if (!channel) return;

  channel.push("chat:sync", { lastIndex }).receive("ok", (resp) => {
    if (!resp.messages || resp.messages.length === 0) {
      return;
    }

    getStore().syncAgentMessages(agentId, resp);

    const updatedCache = getStore().agentsCache[agentId];
    if (!updatedCache) {
      return;
    }

    // The server counts the rows the client should be holding, so holding all
    // of them is the drain's success condition.
    if (
      typeof resp.messageCount === "number" &&
      updatedCache.messages.length >= resp.messageCount
    ) {
      return;
    }

    // Otherwise keep going only while the cache reaches past the bound this
    // request used. The compaction path deliberately asks from the archived
    // boundary, which sits *below* a tail the client already holds, so its
    // reply is filled with rows the client already has: "this reply added
    // nothing" there does not mean the drain is finished — the next request,
    // made from the tail, is the one that fetches what is above it. When the
    // bound *is* the tail, a reply that added nothing means the server has
    // nothing above it, which is where the loop ends.
    if (updatedCache.lastIndex <= lastIndex) {
      return;
    }

    requestSync(agentId, { lastIndex: updatedCache.lastIndex });
  });
}

/**
 * Fetch a page of the agent's archive over `chat:history`. The
 * `role` selects which projection the reply lands in:
 *
 *   * `"compaction"` (with `limit: 1`) → the latest marker goes to
 *     `setAgentCompactionMarker`;
 *   * `"user"` → the recent prompts behind the recall list go to
 *     `setAgentHistoryPrompts`;
 *   * omitted → the page is merged into the expanded card via
 *     `setAgentHistorySlice`. Paging back uses
 *     `{before: firstLoadedIndex}`; the server returns ascending
 *     rows and an empty page once index 0 is passed.
 *
 * A no-op when the channel isn't connected.
 */
export function requestHistory(agentId, opts = {}) {
  const channel = agentChannels.get(agentId);
  if (!channel) return;

  const payload = {};
  if (typeof opts.before === "number") payload.before = opts.before;
  if (typeof opts.limit === "number") payload.limit = opts.limit;
  if (opts.role) payload.role = opts.role;

  // Only the full-slice fetch drives the expanded card, so only its
  // failures set the card-visible error; the marker/prompt refetches
  // failing would be a different (invisible) problem.
  const isSlice = !opts.role;

  channel
    .push("chat:history", payload)
    .receive("ok", (resp) => {
      const rows = Array.isArray(resp?.messages) ? resp.messages : [];
      const store = getStore();

      if (opts.role === "compaction") {
        store.setAgentCompactionMarker(
          agentId,
          rows.length > 0 ? rows[rows.length - 1] : null,
        );
      } else if (opts.role === "user") {
        store.setAgentHistoryPrompts(agentId, rows);
      } else {
        store.setAgentHistorySlice(agentId, rows);
      }
    })
    .receive("error", (resp) => {
      if (isSlice) {
        getStore().setAgentHistoryError(
          agentId,
          resp?.reason ?? "history_fetch_failed",
        );
      }
    })
    .receive("timeout", () => {
      if (isSlice) getStore().setAgentHistoryError(agentId, "history_timeout");
    });
}

/**
 * Fire the two small archive projections an agent with a compaction
 * boundary needs up front (the latest marker and the recent user
 * prompts). The full slice is only fetched on expand. No-op when the
 * agent has never compacted.
 */
function loadArchiveProjections(agentId) {
  const cache = getStore().agentsCache[agentId];
  const lastCompactionIndex = cache?.lastCompactionIndex ?? -1;
  if (lastCompactionIndex < 0) return;
  requestHistory(agentId, { role: "compaction", limit: 1 });
  requestHistory(agentId, { role: "user", limit: 20 });
}

/**
 * Join agent channel.
 *
 * The backend topic is `agent:<space_id>:<name>`, so the
 * caller must supply the agent's `spaceId` (resolved from the
 * route / store). Idempotent: if already connected, sends a
 * status check.
 */
export function joinAgent(agentId, spaceId) {
  const store = getStore();
  const existingChannel = agentChannels.get(agentId);

  if (existingChannel) {
    existingChannel.push("chat:status", {}).receive("ok", (payload) => {
      // Capture the boundary the cache was built around before
      // `setAgentConnected` overwrites it, so a missed compaction whose
      // boundary sits below a drifted cached tail is still detected.
      const priorBoundary =
        getStore().agentsCache[agentId]?.lastCompactionIndex ?? -1;
      store.setAgentConnected(agentId, payload);
      reconcileAgentCache(store, agentId, payload, priorBoundary);
      // `chat:status` carries `lastCompactionIndex` / `compactionCount`
      // (see `agent_channel.ex`), so `setAgentConnected` above overwrote
      // the cached boundary with the fresh one. That overwrite is why
      // `priorBoundary` has to be captured before that call:
      // `reconcileAgentCache` compares the new boundary against the one
      // the cache was built around to catch a compaction we never saw a
      // broadcast for. `loadArchiveProjections` then keys its marker /
      // prompt fetches off the boundary now sitting on the cache.
      loadArchiveProjections(agentId);
    });
    return;
  }

  store.setAgentConnecting(agentId);

  const channel = socket.channel(`agent:${spaceId}:${agentId}`);
  agentChannels.set(agentId, channel);

  channel.on("init", (payload) => {
    // Capture the boundary the cache was built around before
    // `setAgentConnected` overwrites it (see reconcileAgentCache).
    const priorBoundary =
      getStore().agentsCache[agentId]?.lastCompactionIndex ?? -1;
    store.setAgentConnected(agentId, payload);
    store.setAgentInbox(agentId, payload.inbox ?? [], payload.inboxSeq);
    reconcileAgentCache(store, agentId, payload, priorBoundary);
    // The init payload carries the boundary but not the archive; the
    // marker + recall prompts are fetched lazily.
    loadArchiveProjections(agentId);
  });

  channel.on("chat:compaction", (payload) => {
    const marker = payload?.marker ?? null;
    store.setAgentCompaction(agentId, marker);
    if (marker && typeof marker.index === "number") {
      requestSync(agentId, { lastIndex: marker.index });
      // The archive just grew, and the pre-swap user prompts moved
      // out of cache.messages, so both projections are stale.
      loadArchiveProjections(agentId);
    }
  });

  channel.on("chat:compaction-loop", (payload) => {
    store.setCompactionLoop(agentId, {
      content: payload?.content ?? "compaction isn't reducing the conversation",
      attemptCount: payload?.attemptCount,
      maxAttempts: payload?.maxAttempts,
    });
  });

  channel.on("chat:delta", (delta) => {
    const result = store.addChatDelta(agentId, delta);
    if (result.needsSync) {
      console.warn(
        `[agent:${agentId}] Delta gap at ${delta.charsStart}, expected ${store.agentsCache[agentId]?.partial?.charsReceived || 0}. Syncing.`,
      );
      requestSync(agentId);
    }
  });

  channel.on("chat:error", (error) => {
    if (error?.compactionError) {
      store.setCompactionError(agentId, error.content);
    } else {
      store.setAgentError(agentId, error.content);
    }
    store.clearPartial(agentId);
    store.setWaitingForResponse(agentId, false);
  });

  channel.on("chat:message", (message) => {
    const result = store.addChatMessage(agentId, message);
    if (result?.needsSync) {
      const lastIndex =
        typeof result.snapshotLastIndex === "number"
          ? result.snapshotLastIndex
          : undefined;
      requestSync(agentId, { lastIndex });
    }
  });

  channel.on("chat:status", (payload) => {
    if (payload.status === "needs_repair") {
      reconcileAgentCache(store, agentId, payload);
      return;
    }

    store.setAgentState(agentId, payload.status, statusExtras(payload));

    if (payload.status === "idle") {
      store.setWaitingForResponse(agentId, false);
    }
  });

  channel.on("chat:notification", (payload) => {
    store.setNotification(agentId, payload);
  });

  channel.on("shell:jobs", (payload) => {
    store.setAgentJobs(agentId, payload?.jobs ?? []);
  });

  // Async agent-to-agent inbox: the queue is published incrementally
  // (issue #27), one frame per queue change — an append when a peer or a
  // human queues a message, a removal when the agent drains it. A frame that
  // does not continue this client's stream (a missed delta, or an agent that
  // restarted and reset the sequence) is not applied: the client re-requests
  // the whole list over `chat:inbox` and replaces its cache from the reply.
  channel.on("chat:inbox", (payload) => {
    const result = store.applyAgentInboxDelta(agentId, payload);
    if (result?.needsResync) requestInbox(agentId);
  });

  channel.onClose(() => {
    if (joinFailedAgents.has(agentId)) {
      joinFailedAgents.delete(agentId);
      return;
    }
    const currentStore = getStore();
    const cache = currentStore.agentsCache[agentId];
    if (cache?.status === "connected") {
      agentChannels.delete(agentId);
      currentStore.setAgentDisconnected(agentId);
    }
  });

  channel
    .join()
    .receive("ok", () => {})
    .receive("error", (err) => {
      console.error(`Agent ${agentId} channel join error:`, err);
      joinFailedAgents.add(agentId);
      channel.leave();
      agentChannels.delete(agentId);
      // The server can refuse the join with the same
      // `{reason: "config_file_not_regular", path, type}` payload a push
      // gets — opening a chat for an agent whose workspace cannot be
      // protected is the most common way a user meets that refusal — so the
      // shared helper names the offending file instead of leaving the bare
      // reason (or the generic fallback) on the banner.
      store.setAgentError(agentId, errorText(err, "Failed to connect"));
    })
    .receive("timeout", () => {
      console.error(`Agent ${agentId} channel join timeout`);
      joinFailedAgents.add(agentId);
      channel.leave();
      agentChannels.delete(agentId);
      store.setAgentError(agentId, "Connection timed out");
    });
}

/**
 * Leave agent channel
 */
export function leaveAgent(agentId) {
  const channel = agentChannels.get(agentId);
  if (channel) {
    channel.leave();
    agentChannels.delete(agentId);
  }
}

/**
 * Restart the agent (backend stop + start) so it re-reads the DB after
 * an offline `mix nest.repair_messages` run, then rejoin so the fresh
 * `init` reflects the new status. The cached conversation is reset
 * first because the repair can renumber rows, so an incremental
 * `lastIndex` sync would miss shifted messages.
 */
export function reloadAgent(agentId, spaceId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel
    .push("reload_agent", {})
    .receive("ok", () => {
      const store = getStore();
      store.resetAgentConversation(agentId);
      channel.leave();
      agentChannels.delete(agentId);
      joinAgent(agentId, spaceId);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Refresh an agent's async inbox (`agents-send` queue) over
 * `chat:inbox`. This is the **resync** request (issue #27): the reply carries
 * the full list, its length and the `inboxSeq` it was taken at, so the cache
 * is replaced and the delta baseline re-established in one step. The inbox
 * panel calls it on open, and the `chat:inbox` handler calls it when a delta
 * does not continue the client's stream. A no-op when the channel isn't
 * connected.
 */
export function requestInbox(agentId) {
  const channel = agentChannels.get(agentId);
  if (!channel) return;

  channel.push("chat:inbox", {}).receive("ok", (resp) => {
    getStore().setAgentInbox(agentId, resp?.messages ?? [], resp?.inboxSeq);
  });
}

/**
 * Send chat message to specific agent. The optional `mode` selects
 * the sandbox profile for this message's tool calls. The optional
 * `onError` callback fires when the server rejects the push.
 */
export function sendMessage(agentId, content, mode, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  const store = getStore();
  store.addUserMessage(agentId, content, mode);

  const payload = { content };
  if (mode) payload.mode = mode;

  channel
    .push("chat:message", payload)
    .receive("ok", () => {
      store.setWaitingForResponse(agentId, true);
    })
    .receive("error", (err) => {
      // The push was rejected, so the optimistic echo is a phantom: no
      // `chat:message` will ever reconcile it and no `chat:inbox` entry
      // will retract it. This also clears the fabricated assistant
      // placeholders, and only those — a live `partial` from a stream
      // that is still running is left alone.
      store.retractUserMessage(agentId, content);
      if (onError) onError(err);
    });
}

/**
 * Change an agent's mode.
 *
 * The mode is a per-agent runtime property the *server* owns (`Nest.Modes`), so
 * this is a control-plane push rather than a field on the next chat message:
 * the change applies immediately and from the agent's next turn, and the server
 * announces it in the agent's transcript.
 *
 * Optimistic, like `sendMessage`: the selector shows the new mode at once, and
 * a refusal takes it back and reports the reason (the monotone rule refuses a
 * mode an agent may not grant, and the server names why). A no-op when the
 * channel isn't connected.
 */
export function setAgentMode(agentId, mode, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  const store = getStore();
  const previous = store.agentsCache[agentId]?.currentMode ?? null;
  store.setAgentMode(agentId, mode);

  channel.push("set_agent_mode", { mode }).receive("error", (err) => {
    store.setAgentMode(agentId, previous);
    if (onError) onError(err);
  });
}

/**
 * Request that the in-flight chat task for the agent halt
 * immediately. A no-op when the channel isn't connected.
 */
export function stopMessage(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:stop", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Re-run the compactor after a `:compaction_failed` Agent status.
 * A no-op when the channel isn't connected.
 */
export function retryCompaction(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:retry-compaction", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Request that the agent compact its conversation now (`/compact`).
 * `focus`, when non-empty, is the trimmed text after the command and is
 * sent as the compaction focus. Control-plane only: unlike `sendMessage`
 * it appends no user message and does not set `waitingForResponse` — the
 * existing `compacting` status broadcast and compaction divider are the
 * feedback. A no-op when the channel isn't connected.
 */
export function compactAgent(agentId, focus, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  const payload = focus ? { focus } : {};

  channel.push("chat:compact", payload).receive("error", (err) => {
    if (onError) onError(err);
  });
}

/**
 * Acknowledge a `:compaction_loop_detected` status. A no-op when
 * the channel isn't connected.
 */
export function compactionLoopOk(agentId, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  channel.push("chat:loop-detected-ok", {}).receive("error", (err) => {
    if (onError) onError(err);
  });
}
