/**
 * InvitesPage — list / create / revoke invite tokens.
 *
 * Lists the current user's invites (used and unused), lets
 * them mint a fresh invite (the only way to add new users
 * in v1), and revoke unused ones. The token is visible on
 * every row in a copy-friendly cell — the server stores
 * the plaintext in `invites.token`, so there's no one-time
 * window after creation. The "freshly minted" banner is
 * dropped in favor of always-visible tokens.
 *
 * This is a pure renderer over `useStore.invites`. The
 * store is populated by the lobby's `init` payload; create
 * and revoke pushes update the slice in place via
 * `invite:created` / `invite:revoked` listeners registered
 * in `channels.js`. There is NO `useEffect` async fetch —
 * data lives in the store, not in component state.
 *
 * The page gates on `isConnected` (the WS connection is
 * the source of truth for "logged in") rather than
 * `currentUser` (which lags the connection landing via the
 * lobby's `init` push).
 */

import { Navigate } from "react-router-dom";

import { CopyButton } from "../components/CopyButton";
import { createInvite, revokeInvite } from "../channels";
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
  const invites = useStore((state) => state.invites);
  const invitesError = useStore((state) => state.invitesError);
  const setInvitesError = useStore((state) => state.setInvitesError);

  if (!isConnected) {
    return <Navigate to="/login" replace />;
  }

  function handleCreate() {
    setInvitesError(null);
    createInvite();
  }

  function handleRevoke(id) {
    setInvitesError(null);
    revokeInvite(id);
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <h1 className="mb-2 text-xl font-semibold text-gray-900">Invites</h1>
      <p className="mb-4 text-sm text-gray-600">
        Mint a fresh invite token and share it with the person you want to add.
        Anyone with the token can register on this Nest instance.
      </p>

      <button
        type="button"
        onClick={handleCreate}
        className="mb-4 rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
      >
        Create new invite
      </button>

      {invitesError ? (
        <p className="mb-4 rounded bg-red-50 px-3 py-2 text-sm text-red-700">
          {invitesError}
        </p>
      ) : null}

      {invites.length === 0 ? (
        <p className="text-sm text-gray-500">No invites yet.</p>
      ) : (
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b text-left text-xs uppercase text-gray-500">
              <th className="py-2">Status</th>
              <th className="py-2">Token</th>
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
                <tr key={invite.id} className="border-b align-top">
                  <td className="py-2">
                    <span
                      className={`inline-block rounded px-2 py-0.5 text-xs text-white ${
                        status.tone === "green" ? "bg-green-600" : "bg-gray-500"
                      }`}
                    >
                      {status.label}
                    </span>
                  </td>
                  <td className="py-2">
                    <code className="break-all font-mono text-xs text-gray-800">
                      {invite.token}
                    </code>
                    <CopyButton
                      getText={() => invite.token}
                      label="Copy invite token"
                    />
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
                        className="text-xs text-red-600 hover:underline"
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
