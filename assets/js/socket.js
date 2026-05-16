/**
 * Phoenix Socket singleton for WebSocket connections.
 *
 * Initializes a single socket connection that can be used across the app.
 * Auto-connects on import and handles reconnection.
 */

import { Socket } from "phoenix";

const SOCKET_URL = "/socket";

/**
 * Get CSRF token from meta tag
 */
function getCSRFToken() {
  const tokenElement = document.querySelector("meta[name='csrf-token']");
  return tokenElement ? tokenElement.getAttribute("content") : "";
}

/**
 * Initialize and connect the socket
 */
function createSocket() {
  const socket = new Socket(SOCKET_URL, {
    params: { _csrf_token: getCSRFToken() },
  });

  socket.connect();

  // Log connection events in development
  if (process.env.NODE_ENV === "development") {
    socket.onOpen(() => console.log("Socket connected"));
    socket.onClose(() => console.log("Socket disconnected"));
    socket.onError((error) => console.error("Socket error:", error));
  }

  return socket;
}

// Create singleton instance
let socketInstance = null;

/**
 * Get or create the socket instance
 */
export function getSocket() {
  if (!socketInstance) {
    socketInstance = createSocket();
  }
  return socketInstance;
}

/**
 * Join a channel and return it
 *
 * @param {string} topic - Channel topic (e.g., "lobby", "agent:clever-raven")
 * @returns {Channel} Phoenix channel instance
 */
export function joinChannel(topic) {
  const socket = getSocket();
  const channel = socket.channel(topic);

  channel
    .join()
    .receive("ok", () => {
      if (process.env.NODE_ENV === "development") {
        console.log(`Joined channel: ${topic}`);
      }
    })
    .receive("error", (resp) => {
      console.error(`Failed to join channel ${topic}:`, resp);
    });

  return channel;
}

/**
 * Leave a channel
 *
 * @param {Channel} channel - Channel to leave
 */
export function leaveChannel(channel) {
  if (channel) {
    channel.leave();
    if (process.env.NODE_ENV === "development") {
      console.log(`Left channel: ${channel.topic}`);
    }
  }
}

// Export singleton for direct access
export default getSocket();
