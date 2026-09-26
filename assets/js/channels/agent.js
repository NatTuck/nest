/**
 * Agent-channel functions: joining/leaving an agent channel and the
 * chat actions (send/stop/retry/loop-ok). Split from `channels.js` to
 * keep that file under the source-line cap.
 */

import {
  agentChannels,
  getStore,
  joinFailedAgents,
  socket,
  syncState,
} from "./state";

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

  return extra;
}

/**
 * Request a `chat:sync` for the agent. Pushes the request
 * and updates the cache from the response. Multiple
 * overlapping calls fire multiple pushes (the response
 * merge is idempotent).
 *
 * Callers may pass `{lastIndex: number}` to override the
 * lower bound (e.g. the chat:compaction handler passes
 * `marker.index` so the sync pulls only the new active
 * messages). When `lastIndex` is omitted, the agent's
 * `cache.lastIndex` is used.
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
      syncState.delete(agentId);
      return;
    }

    getStore().syncAgentMessages(agentId, resp);

    const updatedCache = getStore().agentsCache[agentId];
    if (updatedCache) {
      requestSync(agentId, { lastIndex: updatedCache.lastIndex });
    }
  });
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
      store.setAgentConnected(agentId, payload);
      const cache = getStore().agentsCache[agentId];
      if (
        cache &&
        typeof payload.messageCount === "number" &&
        payload.messageCount > (cache.messages?.length ?? 0)
      ) {
        requestSync(agentId);
      }
    });
    return;
  }

  store.setAgentConnecting(agentId);

  const channel = socket.channel(`agent:${spaceId}:${agentId}`);
  agentChannels.set(agentId, channel);

  channel.on("init", (payload) => {
    store.setAgentConnected(agentId, payload);
    if (payload.status === "needs_repair") {
      store.setAgentState(agentId, "needs_repair", statusExtras(payload));
    }
    const cache = getStore().agentsCache[agentId];
    if (
      cache &&
      typeof payload.messageCount === "number" &&
      payload.messageCount > (cache.messages?.length ?? 0)
    ) {
      requestSync(agentId);
    }
  });

  channel.on("chat:compaction", (payload) => {
    const history = Array.isArray(payload?.history) ? payload.history : [];
    const marker = payload?.marker ?? null;
    store.setAgentHistory(agentId, history, marker);
    if (marker && typeof marker.index === "number") {
      requestSync(agentId, { lastIndex: marker.index });
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
    store.setAgentState(agentId, payload.status, statusExtras(payload));

    if (payload.status === "idle") {
      store.setWaitingForResponse(agentId, false);
    }
  });

  channel.on("chat:notification", (payload) => {
    store.setNotification(agentId, payload);
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
      store.setAgentError(agentId, err.reason || "Failed to connect");
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
  syncState.delete(agentId);
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
      store.clearPartial(agentId);
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
