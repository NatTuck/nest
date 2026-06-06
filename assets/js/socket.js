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

export { socket };
