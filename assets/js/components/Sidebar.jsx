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

import { useState } from "react";
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
function AgentTreeRow({
  node,
  depth,
  location,
  navigate,
  onDelete,
  spaceSlug,
}) {
  const { agent, children } = node;
  const isCurrent =
    location.pathname ===
    `/space/${spaceSlug}/agent/${encodeURIComponent(agent.name)}`;
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
          to={`/space/${spaceSlug}/agent/${encodeURIComponent(agent.name)}`}
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
            onClick={(e) => onDelete(e, agent.name, agent.space_id)}
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
              spaceSlug={spaceSlug}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

/**
 * A single space row: a collapsible header (name + agent count)
 * that expands to that space's agent tree. Clicking the space
 * name navigates to its Main View (`/space/:slug`); the chevron
 * toggles the agent list.
 */
function SpaceRow({
  space,
  spaceAgents,
  location,
  navigate,
  onDelete,
  isSelected,
}) {
  const [expanded, setExpanded] = useState(isSelected);
  const tree = buildAgentTree(spaceAgents);

  return (
    <li key={space.id}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${isSelected ? "bg-blue-50 text-blue-700 border border-blue-200" : "text-gray-700 hover:bg-gray-100"}
        `}
      >
        <Link
          to={`/space/${encodeURIComponent(space.slug)}`}
          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
        >
          <span className="truncate text-sm font-medium">{space.name}</span>
          <span className="text-xs text-gray-400 ml-1">
            ({spaceAgents.length})
          </span>
        </Link>
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          className="p-1 mr-1 rounded hover:bg-gray-100 text-gray-400"
          aria-label={`Toggle ${space.name}`}
        >
          <svg
            className={`w-4 h-4 transition-transform ${expanded ? "rotate-90" : ""}`}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9 5l7 7-7 7"
            />
          </svg>
        </button>
      </div>
      {expanded && (
        <ul className="space-y-1 mt-1">
          {tree.map((node) => (
            <AgentTreeRow
              key={node.agent.name}
              node={node}
              depth={0}
              location={location}
              navigate={navigate}
              onDelete={onDelete}
              spaceSlug={space.slug}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

// Resolve a space's slug from its id (for post-delete navigation).
function slugFor(spaceId, spaces) {
  return spaces.find((s) => s.id === spaceId)?.slug ?? null;
}

/**
 * Sidebar component
 */
export function Sidebar() {
  const location = useLocation();
  const navigate = useNavigate();
  const { agents, brokenAgents, spaces, currentSpaceId } = useStore();

  const handleDeleteAgent = (e, name, spaceId) => {
    e.preventDefault();
    e.stopPropagation();

    deleteAgent(name, spaceId, (error) => {
      console.error("Failed to delete agent:", error);
    });
    const slug = slugFor(spaceId, spaces);
    // Navigate off a deleted agent's chat page (space-aware).
    if (location.pathname.endsWith(`/agent/${encodeURIComponent(name)}`)) {
      navigate(slug ? `/space/${slug}` : "/spaces");
    }
  };

  const isActive = (path) => {
    if (path === "/spaces/new") {
      return location.pathname === path;
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
          to="/spaces/new"
          className={`
            w-full flex items-center gap-2 px-4 py-2 rounded-lg mb-4
            transition-colors duration-200
            ${
              isActive("/spaces/new")
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
          <span>New Space</span>
        </Link>

        {/* Spaces Section — each space expands to its agent tree */}
        <div className="mb-6">
          <h2 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2 px-2">
            Spaces
          </h2>

          {(spaces?.length ?? 0) === 0 ? (
            <p className="text-sm text-gray-400 px-2 py-2">
              No spaces yet. Create one!
            </p>
          ) : (
            <ul className="space-y-1">
              {spaces.map((space) => (
                <SpaceRow
                  key={space.id}
                  space={space}
                  spaceAgents={agents.filter((a) => a.space_id === space.id)}
                  location={location}
                  navigate={navigate}
                  onDelete={handleDeleteAgent}
                  isSelected={currentSpaceId === space.id}
                />
              ))}
            </ul>
          )}
        </div>

        {/* Needs Repair section — surfaces persistent rows whose
            GenServer is gone (e.g. crashed, or never created in
            this BEAM session with persistence on). The store
            keeps them in `state.brokenAgents` from the lobby's
            `init`/`broken_agents_updated` payloads; the agents
            list above cannot show them because their GenServer
            is dead. Clicking a row navigates to the chat page,
            which triggers the existing :model_missing banner
            and the "Choose replacement model" CTA. The row
            disappears from this list once the user picks a
            replacement (`applyAgentModelUpdate` drops the
            name from `state.brokenAgents`). */}
        {brokenAgents.length > 0 && (
          <div className="mb-6">
            <h2 className="text-xs font-semibold text-amber-700 uppercase tracking-wider mb-2 px-2 flex items-center gap-2">
              <span>Needs Repair</span>
              <span className="text-amber-600 bg-amber-100 px-1.5 py-0.5 rounded-full normal-case font-medium tracking-normal">
                {brokenAgents.length}
              </span>
            </h2>

            <ul className="space-y-1">
              {brokenAgents.map((entry) => {
                const isCurrent = location.pathname === `/agent/${entry.name}`;
                return (
                  <li key={entry.name}>
                    <div
                      className={`
                        flex items-center justify-between rounded-lg group
                        transition-colors duration-200
                        ${
                          isCurrent
                            ? "bg-amber-50 text-amber-800 border border-amber-200"
                            : "text-gray-700 hover:bg-amber-50"
                        }
                      `}
                    >
                      <Link
                        to={`/agent/${entry.name}`}
                        className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
                      >
                        <div className="w-2 h-2 rounded-full flex-shrink-0 bg-amber-500 animate-pulse" />
                        <span className="truncate text-sm font-medium">
                          {entry.name}
                        </span>
                      </Link>

                      <button
                        type="button"
                        onClick={(e) =>
                          handleDeleteAgent(e, entry.name, entry.space_id)
                        }
                        className="
                          opacity-0 group-hover:opacity-100
                          p-1 mr-1 rounded hover:bg-red-100 text-gray-400 hover:text-red-600
                          transition-all duration-200
                        "
                        title={`Delete ${entry.name}`}
                        aria-label={`Delete ${entry.name}`}
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
                    </div>
                  </li>
                );
              })}
            </ul>
          </div>
        )}

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
        <CurrentUserBar />
      </div>
    </aside>
  );
}

/**
 * Footer block showing the current user and a logout button.
 * Reads `currentUser` from the main store; when unset (e.g.
 * the socket's `init` payload hasn't arrived yet), renders
 * nothing.
 */
function CurrentUserBar() {
  const currentUser = useStore((state) => state.currentUser);
  const logout = useStore((state) => state.logout);
  const navigate = useNavigate();

  if (!currentUser) {
    return <p className="text-xs text-gray-400">Nest v0.1.0</p>;
  }

  function handleLogout() {
    // Order matters: disconnect the WS first so no further
    // pushes arrive, then wipe every piece of session state
    // (agents, agentsCache, invites, currentUser, ...) in
    // one store write. After both, navigate to /login so the
    // user lands on the auth surface.
    const sock = window.__nest_socket;
    if (sock && typeof sock.disconnect === "function") {
      sock.disconnect();
    }
    logout();
    navigate("/login", { replace: true });
  }

  return (
    <div className="space-y-2">
      <p className="truncate text-sm font-medium text-gray-700">
        {currentUser.username}
        {currentUser.is_admin ? (
          <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs text-amber-800">
            admin
          </span>
        ) : null}
      </p>
      <div className="flex gap-2">
        <Link
          to="/invites"
          className="flex-1 rounded border border-gray-300 px-2 py-1 text-center text-xs text-gray-700 hover:bg-gray-50"
        >
          Invites
        </Link>
        <button
          type="button"
          onClick={handleLogout}
          className="flex-1 rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-50"
        >
          Logout
        </button>
      </div>
    </div>
  );
}

export default Sidebar;
