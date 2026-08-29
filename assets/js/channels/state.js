/**
 * Shared mutable channel state for the channels module.
 *
 * These refs are deliberately NOT in the zustand store — they're
 * process-global mutable references to live Phoenix channels. The
 * per-module `channels.js` split (`agent.js`, `lobby.js`) all read
 * and mutate these through this single module so they stay in sync.
 */

import { socket } from "../socket";
import { useStore } from "../store";

export { socket };

// Module-level channel refs (NOT in store - they're mutable references)
export const agentChannels = new Map(); // agentId -> Channel
export const joinFailedAgents = new Set(); // Track agents that failed to join

// Per-agent sync state. The inFlight flag is set when a
// `chat:sync` push is in flight and cleared on success. The
// map is cleared per-agent by `leaveAgent`. No coalescing:
// a requestSync call while another is in flight simply
// fires a second push — `syncAgentMessages` is idempotent
// (it merges by index), so duplicate responses don't
// double-add messages.
export const syncState = new Map(); // agentId -> {inFlight}

export let lobbyChannel = null;

export function setLobbyChannel(channel) {
  lobbyChannel = channel;
}

export function clearLobbyChannel() {
  lobbyChannel = null;
}

/**
 * Get the socket instance
 * @returns {Object} The socket instance
 */
export function getSocket() {
  return socket;
}

export function getStore() {
  return useStore.getState();
}

/**
 * Clear all agent channels (for testing)
 */
export function clearAgentChannels() {
  agentChannels.clear();
}
