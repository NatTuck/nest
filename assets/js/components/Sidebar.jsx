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

import { Link, useLocation, useNavigate } from "react-router-dom";
import { useStore } from "../store";
import { ArchivedSpaceRow } from "./SidebarArchivedRow";
import { SpaceRow } from "./SidebarSpaceRow";

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
    currentUser,
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

        {currentUser?.is_admin && (
          <Link
            to="/providers"
            className={`
              flex items-center gap-2 px-3 py-2 rounded-lg
              transition-colors duration-200
              ${
                isActive("/providers")
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
              aria-label="Providers icon"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"
              />
            </svg>
            <span>Providers</span>
          </Link>
        )}
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
