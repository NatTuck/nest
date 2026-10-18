/**
 * A single space row in the sidebar: a collapsible header (name + agent
 * count) that expands to that space's agent tree, with links to the space's
 * own pages and its archive control. Extracted from `Sidebar` to keep that
 * file under the source-line cap; the rows it expands to live in
 * `SidebarAgentTree`.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { archiveSpace } from "../channels";
import {
  NO_ANCESTORS,
  NO_ARCHIVED_GROUPS,
  ancestorGroupKeys,
  ancestorNames,
  buildAgentTree,
  currentAgentName,
  spaceNodeKey,
} from "../utils/agentTree";
import { AgentTreeRow, ArchivedGroup } from "./SidebarAgentTree";

/**
 * True when the current route is this space's overview or one
 * of its agent chat pages. Mirrors how agent rows and archived
 * rows derive their "current" styling from the URL: the space's
 * name links to `/space/:slug`, so the pathname carries the
 * (encoded) slug for both `/space/:slug` and `/space/:slug/...`.
 *
 * `spaceBase` is that encoded `/space/:slug` prefix, so the encoding
 * happens once in `SpaceRow` and every comparison here and below uses the
 * same string the pathname does.
 */
function isSpaceActive(location, spaceBase) {
  return (
    location.pathname === spaceBase ||
    location.pathname.startsWith(`${spaceBase}/`)
  );
}

/**
 * A collapsible space row: header (name + agent count) that expands to
 * the space's agent tree, plus overview and archive. Clicking the name
 * navigates to `/space/:slug` (the space's Main View); the overview icon
 * opens `/space/:slug/overview` (the space's own page: its environment and
 * its agents); the chevron toggles the agent list.
 *
 * The overview icon is here rather than in the agent header because it is the
 * *space's* page, and this is the space's own row — the same reason archive is
 * here. It is also the only entry point that exists on every page: a space whose
 * blueprint names an `rpg` Main View has no agent header at all, so a header
 * link would leave that space's environment with no way in from its main
 * screen. Unlike archive (destructive, and hidden until hover) it is always
 * visible, because it is the one route to the space's settings.
 *
 * Root-level default: the space row for the space in the current route
 * starts expanded, so opening a space shows its agent list without a click
 * — the URL already says which space you are in, so this mirrors the route
 * rather than remembering a choice. Every other space row starts collapsed,
 * and every agent row under it starts collapsed except the current agent's
 * ancestors (see `AgentTreeRow`), so expanding a space reveals exactly one
 * level. Navigating between spaces moves the expansion with the route (see
 * the `useEffect` below).
 *
 * A space row holding the current agent is pinned open, like that agent's
 * ancestor rows: collapsing it would hide the agent the route is on, which is
 * the one thing the expansion policy promises not to do. With no agent
 * selected (the space's own overview page) the row toggles freely — there is
 * nothing to lose sight of.
 *
 * This one row keeps its disclosure in component state on purpose: it is
 * derived from the route rather than a choice to remember, and the effect
 * re-derives it whenever the route moves. (The agent rows below it are the
 * opposite case — their disclosure is a choice, so it lives in the store.)
 */
export function SpaceRow({
  space,
  spaceAgents,
  spaceArchivedAgents = [],
  location,
}) {
  // The slug goes into links and into every route comparison below, so it is
  // encoded once here: the pathname carries the encoded form, and a slug the
  // browser had to escape (`my space`) would match nothing otherwise.
  const spaceSlug = encodeURIComponent(space.slug);
  const spaceBase = `/space/${spaceSlug}`;
  const overviewPath = `${spaceBase}/overview`;
  const selected = isSpaceActive(location, spaceBase);
  const onOverview = location.pathname === overviewPath;
  const [rowExpanded, setRowExpanded] = useState(selected);

  // `selected` is derived from the route, so it changes when the user
  // navigates between spaces. Follow it: `useState` only reads its argument
  // on mount, so without this the row the user just left would stay open and
  // two space rows could be open at once. A manual toggle survives until the
  // route moves again.
  useEffect(() => {
    setRowExpanded(selected);
  }, [selected]);

  const tree = buildAgentTree([...spaceAgents, ...spaceArchivedAgents]);
  const activeRoots = tree.filter((node) => node.agent.archived !== true);
  const archivedRoots = tree.filter((node) => node.agent.archived === true);

  // The current agent's ancestor chain is forced open, so the agent the route
  // selects is always visible. An active agent's ancestors are active too
  // (archiving recurses, and restoring a child whose parent is archived is
  // refused), so the only chain that can run through an `Archived (N)` group
  // is an archived current agent's — and that group opens with it.
  const currentName = currentAgentName(location, spaceSlug);
  const ancestors = currentName
    ? ancestorNames(tree, currentName)
    : NO_ANCESTORS;
  const openGroups = currentName
    ? ancestorGroupKeys(space.id, tree, currentName)
    : NO_ARCHIVED_GROUPS;

  // The row is pinned while an agent below it is selected, so the chain cannot
  // be closed out from under the agent the route is on.
  const pinned = selected && currentName !== null;
  const expanded = pinned || rowExpanded;

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
          to={spaceBase}
          className="flex items-center gap-2 min-w-0 flex-1 px-3 py-2"
        >
          <span className="truncate text-sm font-medium">{space.name}</span>
          <span className="text-xs text-gray-400 ml-1">
            ({spaceAgents.length})
          </span>
        </Link>
        <Link
          to={overviewPath}
          aria-label={`Overview of ${space.name}`}
          aria-current={onOverview ? "page" : undefined}
          title="Space overview — environment and agents"
          className={`
            p-1 rounded transition-colors
            ${
              onOverview
                ? "text-blue-600"
                : "text-gray-400 hover:bg-gray-100 hover:text-gray-700"
            }
          `}
        >
          <svg
            className="w-4 h-4"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <rect x="3" y="4" width="18" height="16" rx="2" strokeWidth={2} />
            <path strokeLinecap="round" strokeWidth={2} d="M3 10h18" />
          </svg>
        </Link>
        <button
          type="button"
          onClick={() => {
            if (!pinned) setRowExpanded((v) => !v);
          }}
          className="p-1 mr-1 rounded hover:bg-gray-100 text-gray-400"
          aria-label={`Toggle ${space.name}`}
          aria-expanded={expanded}
          aria-disabled={pinned || undefined}
          title={
            pinned ? "Holds the current agent — stays expanded" : undefined
          }
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
          {activeRoots.map((node) => (
            <AgentTreeRow
              key={node.agent.name}
              node={node}
              depth={0}
              location={location}
              spaceSlug={spaceSlug}
              spaceId={space.id}
              ancestors={ancestors}
              openGroups={openGroups}
            />
          ))}
          <ArchivedGroup
            nodes={archivedRoots}
            depth={0}
            location={location}
            spaceSlug={spaceSlug}
            spaceId={space.id}
            nodeKey={spaceNodeKey(space.id)}
            ancestors={ancestors}
            openGroups={openGroups}
            toggleLabel={`Toggle archived agents in ${space.name}`}
          />
        </ul>
      )}
    </li>
  );
}
