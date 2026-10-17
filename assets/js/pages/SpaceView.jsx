/**
 * SpaceView (Main View) — shows a space's overview: its name,
 * blueprint, and the agents running in it, with links to each
 * agent's chat page.
 *
 * Phase 4 plans a blueprint-driven layout via `main_view_config`;
 * until a blueprint ships a custom config, this renders the
 * default "space overview" (active agents + status).
 */

import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useStore } from "../store";
import { setSpaceNetwork } from "../channels";
import { useDocumentTitle } from "../hooks/useDocumentTitle";
import { StatusDot } from "../components/StatusDot";

/**
 * Space View component
 */
export function SpaceView() {
  const { spaceSlug } = useParams();
  const spaces = useStore((s) => s.spaces);
  const agents = useStore((s) => s.agents);
  const blueprints = useStore((s) => s.blueprints);
  const setSpaceNetworkAccess = useStore((s) => s.setSpaceNetworkAccess);

  const space = spaces.find((s) => s.slug === spaceSlug);
  const [networkPending, setNetworkPending] = useState(false);
  const [networkError, setNetworkError] = useState(null);
  // The tab names the host and the space. The name falls back to the
  // slug when the store hasn't loaded the space yet (a hard load of a
  // deep URL) -- the slug is real information, so it beats a blank or
  // a placeholder.
  useDocumentTitle([space?.name ?? spaceSlug]);
  const blueprint = space
    ? blueprints.find((b) => b.id === space.blueprint_id)
    : null;
  const spaceAgents = space
    ? agents.filter((a) => a.space_id === space.id)
    : [];

  if (!space) {
    return (
      <div className="max-w-4xl mx-auto py-12 text-center">
        <h1 className="text-2xl font-bold text-gray-900 mb-2">
          Space not found
        </h1>
        <Link to="/spaces" className="text-blue-600 hover:underline">
          Back to spaces
        </Link>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto py-10">
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900">{space.name}</h1>
        {blueprint && (
          <p className="text-sm text-gray-500 mt-1">
            Blueprint: {blueprint.name}
          </p>
        )}

        {/* Network access is the *space's*, not a mode's: it applies to every
            agent here, and it takes effect for their next commands. */}
        <div className="mt-4 flex items-start gap-3">
          <input
            id="space-network-access"
            type="checkbox"
            checked={space.network_access === true}
            disabled={networkPending}
            onChange={(e) => {
              const next = e.target.checked;
              setNetworkPending(true);
              setNetworkError(null);
              setSpaceNetwork(
                space.id,
                next,
                () => {
                  setSpaceNetworkAccess(space.id, next);
                  setNetworkPending(false);
                },
                (err) => {
                  setNetworkPending(false);
                  setNetworkError(
                    err?.reason || "Failed to change network access",
                  );
                },
              );
            }}
            className="mt-0.5 h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 disabled:opacity-50"
          />
          <div>
            <label
              htmlFor="space-network-access"
              className="text-sm font-medium text-gray-700"
            >
              Network access
            </label>
            <p className="text-sm text-gray-500">
              {space.network_access === true
                ? "Agents in this space can reach the network."
                : "Agents in this space cannot reach the network."}
              {space.sandbox_backend === "none" &&
                " This space has no sandbox, so nothing enforces that."}
              {space.sandbox_backend === "docker" &&
                " Changing this restarts this space's container, which clears every agent's /tmp here (offloads and background-job logs) and stops any background job that is still running."}
            </p>
            {networkError && (
              <p className="text-sm text-red-600 mt-1">{networkError}</p>
            )}
          </div>
        </div>
      </div>

      <h2 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">
        Agents
      </h2>

      {spaceAgents.length === 0 ? (
        <p className="text-sm text-gray-400">No agents in this space yet.</p>
      ) : (
        <ul className="space-y-2">
          {spaceAgents.map((agent) => (
            <li
              key={agent.name}
              className="bg-white rounded-lg border border-gray-200 p-4 hover:border-blue-300 transition-colors"
            >
              <Link
                to={`/space/${encodeURIComponent(space.slug)}/agent/${encodeURIComponent(agent.name)}`}
                className="flex items-center justify-between"
              >
                <div className="flex items-center gap-3">
                  <StatusDot status={agent.status} className="w-2.5 h-2.5" />
                  <span className="text-sm font-medium text-gray-800">
                    {agent.name}
                  </span>
                  {agent.depth > 0 && (
                    <span className="text-xs text-gray-400">
                      (depth {agent.depth})
                    </span>
                  )}
                </div>
                <span className="text-xs text-gray-500">{agent.status}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export default SpaceView;
