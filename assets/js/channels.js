/**
 * Channel Management Module
 *
 * Manages Phoenix channel lifecycle separately from state.
 * Holds channel refs as module-level variables.
 */

import { socket } from "./socket";
import { useStore } from "./store";

// Module-level channel refs (NOT in store - they're mutable references)
let lobbyChannel = null;
export const agentChannels = new Map(); // agentId -> Channel
const joinFailedAgents = new Set(); // Track agents that failed to join

/**
 * Get the socket instance
 * @returns {Object} The socket instance
 */
export function getSocket() {
  return socket;
}

/**
 * Clear all agent channels (for testing)
 */
export function clearAgentChannels() {
  agentChannels.clear();
}
function getStore() {
  return useStore.getState();
}

/**
 * Initialize channels module
 */
export function initChannels() {
  const store = getStore();
  socket.onOpen(() => store.setIsConnected(true));
  socket.onClose(() => store.setIsConnected(false));
  socket.onError(() => store.setIsConnected(false));
}

/**
 * Join lobby channel
 */
export function joinLobby(onOk, onError) {
  if (lobbyChannel) {
    if (onOk) onOk();
    return;
  }

  lobbyChannel = socket.channel("lobby");

  lobbyChannel.on("init", (payload) => {
    const store = getStore();
    store.setAgents(payload.agents || []);
    store.setModels(payload.models || []);
    store.setVocations(payload.vocations || []);
  });

  lobbyChannel.on("agent:created", (payload) => {
    const store = getStore();
    store.addAgent(payload);
  });

  lobbyChannel.on("agent:deleted", (payload) => {
    const store = getStore();
    store.removeAgent(payload.id);
  });

  lobbyChannel
    .join()
    .receive("ok", () => {
      if (onOk) onOk();
    })
    .receive("error", (err) => {
      console.error("Lobby channel join error:", err);
      if (onError) onError(err);
    });
}

/**
 * Leave lobby channel
 */
export function leaveLobby() {
  if (lobbyChannel) {
    lobbyChannel.leave();
    lobbyChannel = null;
  }
}

/**
 * Check if we need to sync messages and do so if needed
 */
function checkAndSync(agentId, serverMessageCount) {
  const cache = getStore().agentsCache[agentId];
  const clientMessageCount = cache?.messages?.length ?? 0;
  if (serverMessageCount <= clientMessageCount) {
    return;
  }

  const channel = agentChannels.get(agentId);
  if (!channel) return;

  const lastIndex = cache?.lastIndex ?? -1;
  channel.push("chat:sync", { lastIndex }).receive("ok", (resp) => {
    getStore().syncAgentMessages(agentId, resp);
  });
}

/**
 * Join agent channel
 * Idempotent: if already connected, sends status check
 */
export function joinAgent(agentId) {
  const store = getStore();
  const existingChannel = agentChannels.get(agentId);

  if (existingChannel) {
    existingChannel.push("chat:status", {}).receive("ok", (payload) => {
      store.setAgentConnected(agentId, payload);
      checkAndSync(agentId, payload.messageCount);
    });
    return;
  }

  // Set connecting state
  store.setAgentConnecting(agentId);

  const channel = socket.channel(`agent:${agentId}`);
  agentChannels.set(agentId, channel);

  // Setup event handlers
  channel.on("init", (payload) => {
    store.setAgentConnected(agentId, payload);
    checkAndSync(agentId, payload.messageCount);
  });

  // The backend broadcasts a chat:compaction event when a
  // compaction completes. The payload carries the marker (so the
  // UI can render a divider) and the full archived history. The
  // store replaces the agent's `history` field with the new
  // list, leaving `messages` untouched (the backend has already
  // truncated it to the compacted form).
  channel.on("chat:compaction", (payload) => {
    const history = Array.isArray(payload?.history) ? payload.history : [];
    const marker = payload?.marker ?? null;
    store.setAgentHistory(agentId, history, marker);
  });

  channel.on("chat:delta", (delta) => {
    const result = store.addChatDelta(agentId, delta);
    if (result.needsSync) {
      console.warn(
        `[agent:${agentId}] Delta gap at ${delta.charsStart}, expected ${store.agentsCache[agentId]?.partial?.charsReceived || 0}. Syncing.`,
      );
      checkAndSync(agentId, store.agentsCache[agentId]?.lastIndex ?? -1);
    }
  });

  channel.on("chat:error", (error) => {
    store.setAgentError(agentId, error.content);
    store.clearPartial(agentId);
    store.setWaitingForResponse(agentId, false);
  });

  channel.on("chat:message", (message) => {
    store.addChatMessage(agentId, message);
  });

  channel.on("chat:status", (payload) => {
    // The backend may include the resolved context-window limit and the
    // running usage totals on status pushes (especially the one that
    // follows a successful /models probe and the ones that fire
    // after each LLM response). Forward those fields through
    // `setAgentState`'s extra-arg path so the chip can update live.
    const extra = {};

    if (payload.contextLimit !== undefined) {
      extra.contextLimit = payload.contextLimit;
    }

    if (payload.contextLimitSource !== undefined) {
      extra.contextLimitSource = payload.contextLimitSource;
    }

    if (payload.currentMode !== undefined) {
      // The server includes `currentMode` on every chat:status
      // push so the client can keep the dropdown in sync with
      // the agent's mode (which is updated on each chat send
      // — the "sticky mode" behavior). The ChatPage's
      // `currentMode` React state is updated from this cache
      // value via an effect, so the next message defaults to
      // whatever mode was just used.
      extra.currentMode = payload.currentMode;
    }

    if (payload.usage !== undefined) {
      extra.usage = payload.usage;
    }

    store.setAgentState(agentId, payload.status, extra);

    // When the LLM response completes normally, the agent
    // transitions to :idle. Clear the optimistic "Waiting for
    // response" flag so the chat-level typing indicator
    // disappears.
    //
    // Deltas normally reset it earlier via `addChatDelta`, but
    // thinking-only deltas don't go through the chat:delta
    // broadcast path (see `llm_runner.ex`
    // `forward_thinking_delta/3`) — for a thinking-only
    // response, this is the only reset. We deliberately do NOT
    // reset on "streaming" or "executing_tools": the LLM is
    // still in flight during those states and the indicator
    // should stay visible.
    if (payload.status === "idle") {
      store.setWaitingForResponse(agentId, false);
    }
  });

  channel.on("chat:notification", (payload) => {
    store.setNotification(agentId, payload);
  });

  channel.onClose(() => {
    // Don't set disconnected if join failed (error or timeout)
    // This prevents overwriting error status when Phoenix retries connections
    if (joinFailedAgents.has(agentId)) {
      joinFailedAgents.delete(agentId);
      return;
    }
    // Set disconnected if currently connected (prevents overwriting error status)
    // Must get fresh store state, not use captured 'store' variable
    const currentStore = getStore();
    const cache = currentStore.agentsCache[agentId];
    if (cache?.status === "connected") {
      agentChannels.delete(agentId);
      currentStore.setAgentDisconnected(agentId);
    }
  });

  // Join the channel
  channel
    .join()
    .receive("ok", () => {
      // Wait for init event
    })
    .receive("error", (err) => {
      console.error(`Agent ${agentId} channel join error:`, err);
      joinFailedAgents.add(agentId); // Mark as failed to prevent reconnection
      channel.leave(); // Properly close channel to stop reconnection attempts
      agentChannels.delete(agentId);
      store.setAgentError(agentId, err.reason || "Failed to connect");
    })
    .receive("timeout", () => {
      console.error(`Agent ${agentId} channel join timeout`);
      joinFailedAgents.add(agentId); // Mark as failed to prevent reconnection
      channel.leave(); // Properly close channel to stop reconnection attempts
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
 * Send chat message to specific agent. The optional `mode` selects
 * the sandbox profile for this message's tool calls. The optional
 * `onError` callback fires when the server rejects the push.
 *
 * Call shape is overloaded for back-compat:
 *   sendMessage(id, content)
 *   sendMessage(id, content, onError)
 *   sendMessage(id, content, mode, onError)
 */
export function sendMessage(agentId, content, modeOrOnError, onError) {
  // Back-compat: 3rd arg may be a function (onError) or a string (mode)
  const mode = typeof modeOrOnError === "function" ? undefined : modeOrOnError;
  const errorCallback =
    typeof modeOrOnError === "function" ? modeOrOnError : onError;

  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (errorCallback) errorCallback(new Error("Not connected to agent"));
    return;
  }

  // Optimistically add user message to cache
  const store = getStore();
  store.addUserMessage(agentId, content, mode);

  const payload = { content };
  if (mode) payload.mode = mode;

  channel
    .push("chat:message", payload)
    .receive("ok", () => {
      // Message acknowledged, waiting for assistant response
      store.setWaitingForResponse(agentId, true);
    })
    .receive("error", (err) => {
      // Clear partial on error
      store.clearPartial(agentId);
      if (errorCallback) errorCallback(err);
    });
}

/**
 * Request that the in-flight chat task for the agent halt
 * immediately. The server finalizes whatever was streamed so
 * far and broadcasts `chat:status: "idle"`. The reply is
 * immediate (`{:ok, %{}}`); the actual stop finalization
 * happens asynchronously. The optional `onError` callback
 * fires when the server rejects the push (e.g. agent not
 * found). A no-op when the channel isn't connected.
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
 * Create agent via lobby
 */
export function createAgent(model, vocationId, workspacePath, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  const payload = { model };
  if (vocationId) {
    payload.vocation_id = vocationId;
  }
  if (workspacePath) {
    payload.workspace_path = workspacePath;
  }

  lobbyChannel
    .push("create_agent", payload)
    .receive("ok", (resp) => {
      if (onOk) onOk(resp.id);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    });
}

/**
 * Delete agent via lobby
 */
export function deleteAgent(id, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel.push("delete_agent", { id }).receive("error", (err) => {
    if (onError) onError(err);
  });
}
