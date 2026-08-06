/**
 * Phoenix Socket singleton for WebSocket connections.
 *
 * The socket requires a `token` param sent from the client
 * (read from `localStorage` under the `nest_token` key). The
 * server-side `UserSocket.connect/3` rejects anonymous
 * connections with `:error`, so the UI must surface a login
 * flow whenever `socket.isConnected()` reports `false`.
 *
 * ## Why the connect is lazy
 *
 * `socket.connect()` is NOT called at module load. The
 * socket is wired up here but only opened from
 * `initChannels()` (or from `handleLogout` via the
 * `window.__nest_socket` singleton), and only when a token
 * is present in `localStorage`. The previous top-level
 * `connect()` caused `/login` and `/register` pages to dial
 * `/socket` without a token, which the server logged as a
 * `UserSocket: rejecting connection — missing token` warning
 * followed by a `[info] REFUSED CONNECTION` line — once per
 * reconnect attempt. Since those pages are auth pages and
 * the user can't have a token yet, the connection was always
 * useless and always spammed the dev log.
 *
 * ## Why `params` is the function, not its result
 *
 * Phoenix calls `socket.params()` each time it needs the
 * handshake params (initial connect, auto-reconnect after
 * disconnect). Passing the function (not the called
 * result) means each connect reads a fresh token from
 * `localStorage`. The previous `params: buildParams()`
 * baked the module-load-time snapshot — which had no token
 * for users opening the app for the first time — into
 * every subsequent reconnect, so even after the user logged
 * in, the Socket kept sending stale (token-less) params and
 * the server kept rejecting.
 */

import { Socket } from "phoenix";

const SOCKET_URL = "/socket";
const TOKEN_STORAGE_KEY = "nest_token";

/**
 * Read the auth token from `localStorage`. Returns `null`
 * when no token is stored (or when `localStorage` is
 * unavailable — private mode).
 */
function readAuthToken() {
  try {
    return localStorage.getItem(TOKEN_STORAGE_KEY);
  } catch {
    return null;
  }
}

/**
 * Get CSRF token from meta tag. Kept for backwards
 * compatibility with LiveView's `connect_info: [session:
 * @session_options]`. The auth token is sent as a separate
 * `token` param.
 */
function getCSRFToken() {
  const tokenElement = document.querySelector("meta[name='csrf-token']");
  return tokenElement ? tokenElement.getAttribute("content") : "";
}

/**
 * Build the initial socket params. Called by Phoenix at
 * connect time and on every auto-reconnect, so the token
 * is always read fresh from `localStorage`.
 */
function buildParams() {
  const token = readAuthToken();
  return {
    _csrf_token: getCSRFToken(),
    ...(token ? { token } : {}),
  };
}

const socket = new Socket(SOCKET_URL, {
  params: buildParams,
});

// Expose the singleton so callers (e.g. the logout
// button) can disconnect/reconnect without importing the
// Phoenix socket module — keeps the dependency surface
// minimal in the React component tree.
if (typeof window !== "undefined") {
  window.__nest_socket = socket;
}

export { socket, TOKEN_STORAGE_KEY, readAuthToken, buildParams };
