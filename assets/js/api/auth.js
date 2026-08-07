/**
 * Auth API helpers for the `/api/v1` JSON endpoints.
 *
 * Each function returns the parsed response on success and
 * throws `ApiError` on non-2xx responses so the caller can
 * surface the message in a toast.
 *
 * Logout is intentionally NOT exposed here: the server has
 * no session to clear in v1. Clients drop their
 * `localStorage` entry directly via `clearStoredToken` from
 * `./client` and disconnect the socket via
 * `window.__nest_socket.disconnect()`.
 */

import { apiFetch, setStoredToken } from "./client";

/**
 * POST /api/v1/login — username + password → {token, user}.
 * Stores the returned token in `localStorage` before returning.
 */
export async function login(username, password) {
  const result = await apiFetch("/api/v1/login", {
    method: "POST",
    body: { username, password },
  });

  setStoredToken(result.token);
  return result;
}

/**
 * POST /api/v1/register — username + password + token →
 * {token, user}. The `token` is either a real invite
 * (`Accounts.create_invite/1` output) or the magic
 * `"first-user"` token accepted only on a fresh DB.
 * Stores the returned token in `localStorage` before
 * returning.
 */
export async function register({ username, password, token }) {
  const result = await apiFetch("/api/v1/register", {
    method: "POST",
    body: { username, password, token },
  });

  setStoredToken(result.token);
  return result;
}
