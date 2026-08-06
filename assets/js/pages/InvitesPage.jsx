/**
 * InvitesPage — list / create / revoke invite tokens.
 *
 * Lists the current user's invites (used and unused), lets
 * them mint a fresh invite (the only way to add new users
 * in v1), and revoke unused ones. The freshly-created token
 * is rendered once in a copy-friendly format — the server
 * doesn't store the plaintext and there's no way to recover
 * it after this page is left.
 *
 * This page checks `isConnected` from the main store
 * rather than `currentUser` from the auth store. The WS
 * connection is the source of truth for "logged in" —
 * `currentUser` is set asynchronously by the lobby's
 * `init` push, which can lag the connection landing. If we
 * gated on `currentUser`, a fresh WS connection would
 * bounce the user to /login before the lobby had a chance
 * to populate the user object.
 */

import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";

import { ApiError } from "../api/client";
import { listInvites, createInvite, revokeInvite } from "../api/invites";
import { useStore } from "../store";

function formatDate(iso) {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString();
  } catch {
    return iso;
  }
}

function statusFor(invite) {
  if (invite.revoked_at) return { label: "revoked", tone: "gray" };
  if (invite.used_at) return { label: "used", tone: "gray" };
  if (invite.expires_at && new Date(invite.expires_at) < new Date()) {
    return { label: "expired", tone: "gray" };
  }
  return { label: "active", tone: "green" };
}

export function InvitesPage() {
  const isConnected = useStore((state) => state.isConnected);
  const [invites, setInvites] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [freshToken, setFreshToken] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isConnected) return;
    let cancelled = false;
    setLoading(true);

    listInvites()
      .then((body) => {
        if (cancelled) return;
        setInvites(body.invites || []);
        setLoading(false);
      })
      .catch((err) => {
        if (cancelled) return;
        setError(err instanceof ApiError ? err.message : "Failed to load");
        setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [isConnected]);

  if (!isConnected) {
    return <Navigate to="/login" replace />;
  }

  async function handleCreate() {
    setError(null);
    setBusy(true);
    setFreshToken(null);

    try {
      const result = await createInvite();
      setFreshToken(result.token);
      // Re-fetch the list so the new row appears without a
      // full reload — but skip if the request was canceled.
      const refreshed = await listInvites();
      setInvites(refreshed.invites || []);
    } catch (err) {
      setError(
        err instanceof ApiError ? err.message : "Failed to create invite",
      );
    } finally {
      setBusy(false);
    }
  }

  async function handleRevoke(id) {
    setError(null);
    setBusy(true);

    try {
      await revokeInvite(id);
      const refreshed = await listInvites();
      setInvites(refreshed.invites || []);
    } catch (err) {
      setError(
        err instanceof ApiError ? err.message : "Failed to revoke invite",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mx-auto max-w-2xl p-6">
      <h1 className="mb-2 text-xl font-semibold text-gray-900">Invites</h1>
      <p className="mb-4 text-sm text-gray-600">
        Mint a fresh invite token and share it with the person you want to add.
        The token is shown ONCE when created — copy it then. Anyone with the
        token can register on this Nest instance.
      </p>

      <button
        type="button"
        onClick={handleCreate}
        disabled={busy}
        className="mb-4 rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
      >
        {busy ? "Creating…" : "Create new invite"}
      </button>

      {freshToken ? (
        <div className="mb-4 rounded border border-green-300 bg-green-50 p-3">
          <p className="mb-2 text-sm font-medium text-green-800">
            New invite token — share it now:
          </p>
          <code className="block break-all rounded bg-white px-2 py-1 font-mono text-xs text-gray-800">
            {freshToken}
          </code>
        </div>
      ) : null}

      {error ? (
        <p className="mb-4 rounded bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      ) : null}

      {loading ? (
        <p className="text-sm text-gray-500">Loading…</p>
      ) : invites.length === 0 ? (
        <p className="text-sm text-gray-500">No invites yet.</p>
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b text-left text-xs uppercase text-gray-500">
              <th className="py-2">Status</th>
              <th className="py-2">Created</th>
              <th className="py-2">Expires</th>
              <th className="py-2">Used</th>
              <th className="py-2"></th>
            </tr>
          </thead>
          <tbody>
            {invites.map((invite) => {
              const status = statusFor(invite);
              const revokable = !invite.used_at && !invite.revoked_at;
              return (
                <tr key={invite.id} className="border-b">
                  <td className="py-2">
                    <span
                      className={`inline-block rounded px-2 py-0.5 text-xs text-white ${
                        status.tone === "green" ? "bg-green-600" : "bg-gray-500"
                      }`}
                    >
                      {status.label}
                    </span>
                  </td>
                  <td className="py-2 text-gray-700">
                    {formatDate(invite.inserted_at)}
                  </td>
                  <td className="py-2 text-gray-700">
                    {formatDate(invite.expires_at)}
                  </td>
                  <td className="py-2 text-gray-700">
                    {formatDate(invite.used_at)}
                  </td>
                  <td className="py-2 text-right">
                    {revokable ? (
                      <button
                        type="button"
                        onClick={() => handleRevoke(invite.id)}
                        disabled={busy}
                        className="text-xs text-red-600 hover:underline disabled:opacity-50"
                      >
                        Revoke
                      </button>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default InvitesPage;
