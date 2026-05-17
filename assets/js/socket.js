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

export { socket };
