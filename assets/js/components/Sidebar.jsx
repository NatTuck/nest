/**
 * Sidebar component with navigation and agent list.
 *
 * Features:
 * - New Agent button
 * - List of active agents with delete option
 * - About link
 * - Current route highlighting
 */

import { Link, useLocation, useNavigate } from "react-router";
import { useStore } from "../store";

/**
 * Sidebar component
 */
export function Sidebar() {
  const location = useLocation();
  const navigate = useNavigate();
  const { agents, currentAgentId, deleteAgent } = useStore();

  const handleDeleteAgent = async (e, id) => {
    e.preventDefault();
    e.stopPropagation();

    try {
      await deleteAgent(id);
      // If we deleted the current agent, navigate home
      if (currentAgentId === id) {
        navigate("/");
      }
    } catch (error) {
      console.error("Failed to delete agent:", error);
    }
  };

  const isActive = (path) => {
    if (path === "/") {
      return location.pathname === "/";
    }
    return location.pathname.startsWith(path);
  };

  return (
    <aside className="w-64 bg-white border-r border-gray-200 flex flex-col">
      {/* Header */}
      <div className="p-4 border-b border-gray-200">
        <h1 className="text-xl font-bold text-gray-800">Nest</h1>
        <p className="text-sm text-gray-500">AI Agent Platform</p>
      </div>

      {/* Navigation */}
      <nav className="flex-1 overflow-y-auto p-4">
        {/* New Agent Button */}
        <Link
          to="/"
          className={`
            w-full flex items-center gap-2 px-4 py-2 rounded-lg mb-4
            transition-colors duration-200
            ${
              isActive("/")
                ? "bg-blue-600 text-white"
                : "bg-gray-100 text-gray-700 hover:bg-gray-200"
            }
          `}
        >
          <svg
            className="w-5 h-5"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="Plus icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M12 4v16m8-8H4"
            />
          </svg>
          <span>New Agent</span>
        </Link>

        {/* Active Agents Section */}
        <div className="mb-6">
          <h2 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2 px-2">
            Active Agents
          </h2>

          {agents.length === 0 ? (
            <p className="text-sm text-gray-400 px-2 py-2">
              No agents yet. Create one!
            </p>
          ) : (
            <ul className="space-y-1">
              {agents.map((agent) => (
                <li key={agent.id}>
                  <Link
                    to={`/agent/${agent.id}`}
                    className={`
                      flex items-center justify-between px-3 py-2 rounded-lg
                      transition-colors duration-200 group
                      ${
                        currentAgentId === agent.id
                          ? "bg-blue-50 text-blue-700 border border-blue-200"
                          : "text-gray-700 hover:bg-gray-100"
                      }
                    `}
                  >
                    <div className="flex items-center gap-2 min-w-0">
                      <div
                        className={`
                          w-2 h-2 rounded-full flex-shrink-0
                          ${agent.status === "streaming" ? "bg-green-500 animate-pulse" : "bg-gray-300"}
                        `}
                      />
                      <span className="truncate text-sm font-medium">
                        {agent.id}
                      </span>
                    </div>

                    {/* Delete button */}
                    <button
                      type="button"
                      onClick={(e) => handleDeleteAgent(e, agent.id)}
                      className="
                        opacity-0 group-hover:opacity-100
                        p-1 rounded hover:bg-red-100 text-gray-400 hover:text-red-600
                        transition-all duration-200
                      "
                      title={`Delete ${agent.id}`}
                      aria-label={`Delete ${agent.id}`}
                    >
                      <svg
                        className="w-4 h-4"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                        aria-label="Delete icon"
                      >
                        <path
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth={2}
                          d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                        />
                      </svg>
                    </button>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </div>

        {/* About Link */}
        <Link
          to="/about"
          className={`
            flex items-center gap-2 px-3 py-2 rounded-lg
            transition-colors duration-200
            ${
              isActive("/about")
                ? "bg-blue-50 text-blue-700"
                : "text-gray-600 hover:bg-gray-100"
            }
          `}
        >
          <svg
            className="w-5 h-5"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="About icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <span>About</span>
        </Link>
      </nav>

      {/* Footer */}
      <div className="p-4 border-t border-gray-200">
        <p className="text-xs text-gray-400">Nest v0.1.0</p>
      </div>
    </aside>
  );
}

export default Sidebar;
