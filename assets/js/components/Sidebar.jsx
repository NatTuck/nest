/**
 * Sidebar component with navigation and agent tree.
 *
 * Features:
 * - New Agent button
 * - Tree of active agents (roots at top, children
 *   nested under their parent by name)
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
import { archiveSpace, unarchiveSpace } from "../channels";

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
 * current-agent styling. Leaves and non-leaves alike render
 * identically (there's no delete — archiving happens via the
 * coordinator, and delete is removed in favor of spaces).
 */
function AgentTreeRow({ node, depth, location, spaceSlug }) {
  const { agent, children } = node;
  const isCurrent =
    location.pathname ===
    `/space/${spaceSlug}/agent/${encodeURIComponent(agent.name)}`;
  const hasChildren = children.length > 0;

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
          {hasChildren && (
            <span className="text-xs text-gray-400 ml-1">
              ({children.length})
            </span>
          )}
        </Link>
      </div>
      {hasChildren && (
        <ul className="space-y-1">
          {children.map((child) => (
            <AgentTreeRow
              key={child.agent.name}
              node={child}
              depth={depth + 1}
              location={location}
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
  spaceBrokenAgents,
  location,
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
        <button
          type="button"
          onClick={() => archiveSpace(space.id)}
          className="p-1 mr-1 rounded hover:bg-gray-100 text-gray-400 opacity-0 group-hover:opacity-100 transition-opacity"
          aria-label={`Archive ${space.name}`}
          title="Archive space"
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
              d="M5 8h14M5 8l1.5 11h11L19 8M9 8V6a2 2 0 012-2h2a2 2 0 012 2v2"
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
              spaceSlug={space.slug}
            />
          ))}
          {spaceBrokenAgents.length > 0 && (
            <li className="pl-3 mt-2">
              <p className="text-xs font-semibold text-amber-700 uppercase tracking-wider mb-1">
                Needs Repair
              </p>
              <ul className="space-y-1">
                {spaceBrokenAgents.map((entry) => {
                  const path = `/space/${space.slug}/agent/${encodeURIComponent(entry.name)}`;
                  const isCurrent = location.pathname === path;
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
                          to={path}
                          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
                        >
                          <div className="w-2 h-2 rounded-full flex-shrink-0 bg-amber-500 animate-pulse" />
                          <span className="truncate text-sm font-medium">
                            {entry.name}
                          </span>
                        </Link>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </li>
          )}
        </ul>
      )}
    </li>
  );
}

/**
 * A single archived space row. Archived spaces are stopped and
 * hidden from the main list; this row shows the name and a
 * Restore button that moves it back into the active list.
 */
function ArchivedSpaceRow({ space, location }) {
  const isCurrent = location.pathname === `/space/${space.slug}`;

  return (
    <li key={space.id}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${isCurrent ? "bg-gray-200 text-gray-800" : "text-gray-500 hover:bg-gray-100"}
        `}
      >
        <Link
          to={`/space/${encodeURIComponent(space.slug)}`}
          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
        >
          <div className="w-2 h-2 rounded-full flex-shrink-0 bg-gray-400" />
          <span className="truncate text-sm font-medium">{space.name}</span>
        </Link>
        <button
          type="button"
          onClick={() => unarchiveSpace(space.id)}
          className="mr-1 rounded border border-gray-300 px-2 py-0.5 text-xs text-gray-600 hover:bg-gray-200 opacity-0 group-hover:opacity-100 transition-opacity"
          aria-label={`Restore ${space.name}`}
          title="Restore space"
        >
          Restore
        </button>
      </div>
    </li>
  );
}

/**
 * Sidebar component
 */
export function Sidebar() {
  const location = useLocation();
  const {
    agents,
    brokenAgents,
    spaces,
    archivedSpaces,
    archivedCollapsed,
    setArchivedCollapsed,
    currentSpaceId,
  } = useStore();

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
                  spaceBrokenAgents={brokenAgents.filter(
                    (a) => a.space_id === space.id,
                  )}
                  location={location}
                  isSelected={currentSpaceId === space.id}
                />
              ))}
            </ul>
          )}
        </div>

        {/* Archived Spaces Section — stopped + hidden spaces that
            can be inspected and restored. Collapsed by default. */}
        {(archivedSpaces?.length ?? 0) > 0 && (
          <div className="mb-6">
            <button
              type="button"
              onClick={() => setArchivedCollapsed(!archivedCollapsed)}
              className="w-full flex items-center justify-between text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2 px-2 hover:text-gray-600 transition-colors duration-200"
              aria-expanded={!archivedCollapsed}
              aria-label="Toggle archived spaces"
            >
              <span>Archived</span>
              <svg
                className={`w-4 h-4 transition-transform ${archivedCollapsed ? "" : "rotate-90"}`}
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
            {!archivedCollapsed && (
              <ul className="space-y-1">
                {archivedSpaces.map((space) => (
                  <ArchivedSpaceRow
                    key={space.id}
                    space={space}
                    location={location}
                  />
                ))}
              </ul>
            )}
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
