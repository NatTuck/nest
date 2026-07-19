/**
 * Sidebar component with navigation and agent tree.
 *
 * Features:
 * - New Agent button
 * - Tree of active agents (roots at top, children
 *   nested under their parent by name), with delete on
 *   each leaf
 * - About link
 * - Current route highlighting
 *
 * The tree is rebuilt from the flat `agents` list on every
 * render. The rebuild is cheap (small N) and avoids
 * bookkeeping for `children` arrays on every state
 * mutation. Each agent entry carries `parentName`
 * (camelCase wire format) which the helper resolves.
 */

import { Link, useLocation, useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { deleteAgent } from "../channels";

/**
 * Build a tree from a flat agents list. Each agent's
 * `parentName` is the parent's readable identifier
 * (or `null` for roots). The helper returns
 * `[{ agent, children: [...] }, ...]` for roots, with
 * children recursively nested.
 *
 * Siblings are alphabetized for stable display order.
 */
function buildAgentTree(agents) {
  const byName = new Map();
  for (const a of agents || []) {
    byName.set(a.name, { agent: a, children: [] });
  }
  const roots = [];
  for (const node of byName.values()) {
    const parentName = node.agent.parentName;
    if (parentName && byName.has(parentName)) {
      byName.get(parentName).children.push(node);
    } else {
      roots.push(node);
    }
  }
  const sortChildren = (nodes) => {
    nodes.sort((a, b) => a.agent.name.localeCompare(b.agent.name));
    for (const n of nodes) sortChildren(n.children);
  };
  sortChildren(roots);
  return roots;
}

/**
 * Recursive agent row. Renders the agent's name with the
 * current-agent styling and a delete button (only on
 * leaves — non-leaves have a chevron instead, since
 * deleting a parent would orphan its children).
 */
function AgentTreeRow({ node, depth, location, navigate, onDelete }) {
  const { agent, children } = node;
  const isCurrent = location.pathname === `/agent/${agent.name}`;
  const hasChildren = children.length > 0;
  const isLeaf = !hasChildren;

  return (
    <li key={agent.name}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${isCurrent ? "bg-blue-50 text-blue-700 border border-blue-200" : "text-gray-700 hover:bg-gray-100"}
        `}
      >
        <Link
          to={`/agent/${agent.name}`}
          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
          style={{ paddingLeft: `${0.75 + depth * 0.875}rem` }}
        >
          <div
            className={`
              w-2 h-2 rounded-full flex-shrink-0
              ${agent.status === "streaming" ? "bg-green-500 animate-pulse" : "bg-gray-300"}
              ${agent.status === "executing_tools" ? "bg-amber-500 animate-pulse" : ""}
            `}
          />
          <span className="truncate text-sm font-medium">{agent.name}</span>
          {!isLeaf && (
            <span className="text-xs text-gray-400 ml-1">
              ({children.length})
            </span>
          )}
        </Link>

        {isLeaf && (
          <button
            type="button"
            onClick={(e) => onDelete(e, agent.name)}
            className="
              opacity-0 group-hover:opacity-100
              p-1 mr-1 rounded hover:bg-red-100 text-gray-400 hover:text-red-600
              transition-all duration-200
            "
            title={`Delete ${agent.name}`}
            aria-label={`Delete ${agent.name}`}
          >
            <svg
              className="w-4 h-4"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>
        )}
      </div>
      {!isLeaf && (
        <ul className="space-y-1">
          {children.map((child) => (
            <AgentTreeRow
              key={child.agent.name}
              node={child}
              depth={depth + 1}
              location={location}
              navigate={navigate}
              onDelete={onDelete}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

/**
 * Sidebar component
 */
export function Sidebar() {
  const location = useLocation();
  const navigate = useNavigate();
  const { agents } = useStore();

  const handleDeleteAgent = (e, name) => {
    e.preventDefault();
    e.stopPropagation();

    deleteAgent(name, (error) => {
      console.error("Failed to delete agent:", error);
    });
    if (location.pathname === `/agent/${name}`) {
      navigate("/");
    }
  };

  const isActive = (path) => {
    if (path === "/") {
      return location.pathname === "/";
    }
    return location.pathname.startsWith(path);
  };

  const tree = buildAgentTree(agents);

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

        {/* Active Agents Section (rendered as a tree) */}
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
              {tree.map((node) => (
                <AgentTreeRow
                  key={node.agent.name}
                  node={node}
                  depth={0}
                  location={location}
                  navigate={navigate}
                  onDelete={handleDeleteAgent}
                />
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
