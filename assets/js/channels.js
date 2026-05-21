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
function checkAndSync(agentId, serverLastIndex) {
  const cache = getStore().agentsCache[agentId];
  const cacheLastIndex = cache?.lastIndex ?? -1;
  if (serverLastIndex <= cacheLastIndex) {
    return;
  }

  const channel = agentChannels.get(agentId);
  if (!channel) return;

  channel
    .push("chat:sync", { lastIndex: cacheLastIndex })
    .receive("ok", (resp) => {
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
      checkAndSync(agentId, payload.lastCompleteIndex);
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
    checkAndSync(agentId, payload.lastCompleteIndex);
  });

  channel.on("chat:delta", (delta) => {
    store.addChatDelta(agentId, delta);
  });

  channel.on("chat:error", (error) => {
    store.setAgentError(agentId, error.content);
    store.clearPartial(agentId);
  });

  channel.on("chat:message", (message) => {
    store.addChatMessage(agentId, message);
  });

  channel.onClose(() => {
    agentChannels.delete(agentId);
    store.setAgentDisconnected(agentId);
  });

  // Join the channel
  channel
    .join()
    .receive("ok", () => {
      // Wait for init event
    })
    .receive("error", (err) => {
      agentChannels.delete(agentId);
      store.setAgentError(agentId, err.reason || "Failed to connect");
    })
    .receive("timeout", () => {
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
 * Send chat message to specific agent
 */
export function sendMessage(agentId, content, onError) {
  const channel = agentChannels.get(agentId);
  if (!channel) {
    if (onError) onError(new Error("Not connected to agent"));
    return;
  }

  // Optimistically add user message to cache
  const store = getStore();
  store.addUserMessage(agentId, content);

  channel
    .push("chat:message", { content })
    .receive("ok", () => {
      // Message acknowledged, waiting for assistant response
      store.setWaitingForResponse(agentId, true);
    })
    .receive("error", (err) => {
      // Clear partial on error
      store.clearPartial(agentId);
      if (onError) onError(err);
    });
}

/**
 * Create agent via lobby
 */
export function createAgent(model, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error("Not connected to lobby"));
    return;
  }

  lobbyChannel
    .push("create_agent", { model })
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
