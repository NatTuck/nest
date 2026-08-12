/**
 * SpaceView (Main View) — shows a space's overview: its name,
 * blueprint, and the agents running in it, with links to each
 * agent's chat page.
 *
 * Phase 4 plans a blueprint-driven layout via `main_view_config`;
 * until a blueprint ships a custom config, this renders the
 * default "space overview" (active agents + status).
 */

import { Link, useParams } from "react-router-dom";
import { useStore } from "../store";

/**
 * Space View component
 */
export function SpaceView() {
  const { spaceSlug } = useParams();
  const spaces = useStore((s) => s.spaces);
  const agents = useStore((s) => s.agents);
  const blueprints = useStore((s) => s.blueprints);

  const space = spaces.find((s) => s.slug === spaceSlug);
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
                  <div
                    className={`w-2.5 h-2.5 rounded-full flex-shrink-0 ${
                      agent.status === "streaming"
                        ? "bg-green-500 animate-pulse"
                        : "bg-gray-300"
                    } ${agent.status === "executing_tools" ? "bg-amber-500 animate-pulse" : ""}`}
                  />
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
