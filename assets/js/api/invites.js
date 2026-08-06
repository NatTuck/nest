/**
 * Invite API helpers for the `/api/v1/invites` endpoints.
 *
 * All calls require a stored token (the server uses
 * `Authorization: Bearer …`); the `client.js` wrapper
 * injects it automatically from `localStorage`.
 */

import { apiFetch } from "./client";

/**
 * GET /api/v1/invites → `{invites: [...]}` (caller's own,
 * newest first).
 */
export function listInvites() {
  return apiFetch("/api/v1/invites");
}

/**
 * POST /api/v1/invites → `{id, token, expires_at, …}`. The
 * `token` field is the only place the plaintext invite is
 * ever exposed; the server stores a hash.
 */
export function createInvite() {
  return apiFetch("/api/v1/invites", { method: "POST", body: {} });
}

/**
 * DELETE /api/v1/invites/:id → 204 on success, 403/404/409
 * on the usual failure modes.
 */
export function revokeInvite(id) {
  return apiFetch(`/api/v1/invites/${id}`, { method: "DELETE" });
}
