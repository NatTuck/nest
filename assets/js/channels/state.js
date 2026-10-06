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
