/**
 * A single space row in the sidebar: a collapsible header (name + agent
 * count) that expands to that space's agent tree. Extracted from
 * `Sidebar` to keep that file under the source-line cap.
 */

import { useState } from "react";
import { Link } from "react-router-dom";
import { archiveSpace } from "../channels";

/**
 * Build a tree from a flat agents list. Each agent's
 * `parentName` is the parent's readable identifier
 * (or `null` for roots). The helper returns
 * `[{ agent, children: [...] }, ...]` for roots, with
 * children recursively nested. Siblings are alphabetized.
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
 * True when the current route is this space's overview or one
 * of its agent chat pages. Mirrors how agent rows and archived
 * rows derive their "current" styling from the URL: the space's
 * name links to `/space/:slug`, so the pathname carries the
 * (encoded) slug for both `/space/:slug` and `/space/:slug/...`.
 */
function isSpaceActive(location, space) {
  const base = `/space/${encodeURIComponent(space.slug)}`;
  return location.pathname === base || location.pathname.startsWith(`${base}/`);
}

/**
 * Recursive agent row. Renders the agent's name with the
 * current-agent styling. Leaves and non-leaves alike render
 * identically.
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
 * A collapsible space row: header (name + agent count) that expands to
 * the space's agent tree, plus archive. Clicking the name navigates to
 * `/space/:slug`; the chevron toggles the agent list.
 */
export function SpaceRow({ space, spaceAgents, spaceBrokenAgents, location }) {
  const selected = isSpaceActive(location, space);
  const [expanded, setExpanded] = useState(selected);
  const tree = buildAgentTree(spaceAgents);

  return (
    <li key={space.id}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${selected ? "bg-blue-50 text-blue-700 border border-blue-200" : "text-gray-700 hover:bg-gray-100"}
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
