/**
 * SpacesIndex — the landing page for the authenticated user.
 * Shows the user's spaces as cards, each linking to its Main
 * View. Also offers a "New Space" action.
 */

import { Link } from "react-router-dom";
import { useStore } from "../store";

/**
 * Spaces Index component
 */
export function SpacesIndex() {
  const spaces = useStore((s) => s.spaces);
  const agents = useStore((s) => s.agents);

  return (
    <div className="max-w-4xl mx-auto py-12">
      <div className="flex items-center justify-between mb-8">
        <h1 className="text-3xl font-bold text-gray-900">Spaces</h1>
        <Link
          to="/spaces/new"
          className="px-4 py-2 rounded-lg bg-blue-600 text-white text-sm font-medium hover:bg-blue-700 transition-colors"
        >
          New Space
        </Link>
      </div>

      {spaces.length === 0 ? (
        <p className="text-sm text-gray-400">
          No spaces yet.{" "}
          <Link to="/spaces/new" className="text-blue-600 hover:underline">
            Create one
          </Link>
          .
        </p>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {spaces.map((space) => {
            const count = agents.filter((a) => a.space_id === space.id).length;
            return (
              <Link
                key={space.id}
                to={`/space/${encodeURIComponent(space.slug)}`}
                className="bg-white rounded-xl border border-gray-200 p-6 hover:border-blue-300 hover:shadow-sm transition-all"
              >
                <h2 className="text-lg font-semibold text-gray-800">
                  {space.name}
                </h2>
                <p className="text-sm text-gray-500 mt-1">
                  {count} agent{count === 1 ? "" : "s"}
                </p>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

export default SpacesIndex;
