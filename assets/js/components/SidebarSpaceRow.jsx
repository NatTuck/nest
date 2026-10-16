/**
 * A single space row in the sidebar: a collapsible header (name + agent
 * count) that expands to that space's agent tree. Extracted from
 * `Sidebar` to keep that file under the source-line cap.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { archiveSpace, unarchiveAgent } from "../channels";
import { useStore } from "../store";
import {
  NO_ANCESTORS,
  NO_ARCHIVED_GROUPS,
  agentNodeKey,
  ancestorGroupKeys,
  ancestorNames,
  archivedGroupKey,
  buildAgentTree,
  countArchived,
  currentAgentName,
  spaceNodeKey,
} from "../utils/agentTree";
import { StatusDot } from "./StatusDot";

/**
 * A collapsed-by-default `Archived (N)` group. Rendered at the bottom
 * of an active parent's children (nests archived children under the
 * parent) and at the bottom of a space (for archived roots). Expanding
 * renders the archived subtree through the normal tree rows.
 *
 * Its disclosure lives in the store like an agent row's, keyed off the
 * node it belongs to.
 *
 * One group can be pinned open: the one on the current agent's path when that
 * agent is archived (see `ancestorGroupKeys`). Its row is not a link — the
 * agent is stopped, so the row offers Restore instead — and being archived is
 * exactly why the row is worth showing, so the group that hides it opens and
 * its toggle cannot close it. The rows inside get the same ancestor chain the
 * rest of the tree does, so a current agent further down an archived subtree
 * is reached by that chain the same way.
 */
function ArchivedGroup({
  nodes,
  depth,
  location,
  spaceSlug,
  spaceId,
  nodeKey,
  ancestors,
  openGroups,
  toggleLabel,
}) {
  const groupKey = archivedGroupKey(nodeKey);
  const forced = openGroups.has(groupKey);
  const storedExpanded = useStore(
    (state) => state.expandedTreeNodes[groupKey] === true,
  );
  const toggleTreeNode = useStore((state) => state.toggleTreeNode);
  const expanded = forced || storedExpanded;

  if (nodes.length === 0) return null;

  return (
    <li className="mt-2" style={{ paddingLeft: `${0.75 + depth * 0.875}rem` }}>
      <button
        type="button"
        onClick={() => {
          if (!forced) toggleTreeNode(groupKey);
        }}
        className="flex items-center gap-1 text-xs font-semibold text-gray-400 uppercase tracking-wider mb-1 hover:text-gray-600 transition-colors duration-200"
        aria-expanded={expanded}
        aria-disabled={forced || undefined}
        aria-label={toggleLabel}
        title={forced ? "Holds the current agent — stays expanded" : undefined}
      >
        <svg
          className={`w-3 h-3 transition-transform ${expanded ? "rotate-90" : ""}`}
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
        <span>Archived ({countArchived(nodes)})</span>
      </button>
      {expanded && (
        <ul className="space-y-1">
          {nodes.map((node) => (
            <AgentTreeRow
              key={node.agent.name}
              node={node}
              depth={depth}
              location={location}
              spaceSlug={spaceSlug}
              spaceId={spaceId}
              ancestors={ancestors}
              openGroups={openGroups}
            />
          ))}
        </ul>
      )}
    </li>
  );
}

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
 * The message shown when a restore is refused. The backend names the
 * still-archived parent (`parent_archived`) — the case the user can act
 * on — and anything else falls back to the raw reason.
 */
function restoreErrorMessage(err) {
  if (err?.reason === "parent_archived" && err.parent) {
    return `Parent "${err.parent}" is still archived — restore it first.`;
  }
  return `Could not restore: ${err?.reason ?? "unknown error"}`;
}

/**
 * Recursive agent row. Renders the agent's name with the
 * current-agent styling plus a chevron toggle when the node has
 * children (so a busy parent can be collapsed). Leaves render an
 * aligned spacer instead of a chevron.
 *
 * Default is collapsed: expanding a node reveals exactly its direct
 * children, and each of those starts collapsed too, so a click never
 * unfolds a whole subtree at once. The disclosure lives in the store
 * (`expandedTreeNodes`), so collapsing an ancestor and expanding it again
 * restores the subtree the user had opened — the rows were unmounted in
 * between, which a row-local state could not survive.
 *
 * One exception: the current agent's ancestors are always open, so the agent
 * the route selects is visible wherever it sits in the tree. Those toggles say
 * so (`title` for the mouse, `aria-disabled` for everything else), and a click
 * on one is a no-op rather than a deferred flip: storing the state it cannot
 * show would only surface later, on a route where the row is free to move.
 *
 * Active nodes split their children: active children render inline,
 * archived children render at the bottom behind a collapsed
 * `Archived (N)` group (so they stay nested under the active parent).
 * Inside an archived subtree, descendants are rendered directly.
 *
 * An archived node's label is not a link: its agent is stopped, so the
 * backend refuses to start it for a chat join (`agent_archived`).
 * Linking there would only ever produce that refusal, so the row says
 * what to do instead (Restore).
 */
function AgentTreeRow({
  node,
  depth,
  location,
  spaceSlug,
  spaceId,
  ancestors,
  openGroups,
}) {
  const { agent, children } = node;
  const isCurrent =
    location.pathname ===
    `/space/${spaceSlug}/agent/${encodeURIComponent(agent.name)}`;
  const isArchived = agent.archived === true;
  const activeChildren = isArchived
    ? []
    : children.filter((child) => child.agent.archived !== true);
  const archivedChildren = isArchived
    ? children
    : children.filter((child) => child.agent.archived === true);
  const directChildren = isArchived ? children : activeChildren;
  const hasChildren = activeChildren.length > 0 || archivedChildren.length > 0;
  const nodeKey = agentNodeKey(spaceId, agent.name);
  const storedExpanded = useStore(
    (state) => state.expandedTreeNodes[nodeKey] === true,
  );
  const toggleTreeNode = useStore((state) => state.toggleTreeNode);
  // The client's own view of this agent's channel, which is not the same
  // thing as `agent.status` from the list: the list carries what the server
  // last said, while this carries whether *this* client has finished joining.
  // A narrow selector, so a cache write for another agent (or any other field
  // of this one) does not re-render the row.
  const cacheStatus = useStore(
    (state) => state.agentsCache[agent.name]?.status,
  );
  const onCurrentPath = ancestors.has(agent.name);
  const expanded = onCurrentPath || storedExpanded;
  const [restoreError, setRestoreError] = useState(null);

  // A row is reporting the client's own join state whenever its channel is
  // being joined — and that is not only the row the route selects: clicking a
  // second agent while the first join is still in flight (or leaving for the
  // space overview) leaves that first row `connecting` with the route
  // elsewhere. A row with no cache entry at all is only joining when it is the
  // current one; for any other row, no entry means nobody ever asked to join
  // it, and the list's status is the honest thing to show.
  //
  // Between the click and the channel's `init` reply there is nothing from the
  // server to report, and for a cold agent that window can be seconds long, so
  // the row reports the state it is actually in rather than a stale status the
  // click did not change.
  const joining =
    cacheStatus === "connecting" || (isCurrent && cacheStatus === undefined);

  const label = (
    <>
      <StatusDot
        status={joining ? "connecting" : agent.status}
        className="w-2 h-2"
      />
      <span className="truncate text-sm font-medium">{agent.name}</span>
      {directChildren.length > 0 && (
        <span className="text-xs text-gray-400 ml-1">
          ({directChildren.length})
        </span>
      )}
    </>
  );

  return (
    <li key={agent.name}>
      <div
        className={`
          flex items-center justify-between rounded-lg group
          transition-colors duration-200
          ${isCurrent ? "bg-blue-50 text-blue-700 border border-blue-200" : "text-gray-700 hover:bg-gray-100"}
        `}
        style={{ paddingLeft: `${0.75 + depth * 0.875}rem` }}
      >
        {hasChildren ? (
          <button
            type="button"
            onClick={() => {
              if (!onCurrentPath) toggleTreeNode(nodeKey);
            }}
            className="w-4 h-4 flex items-center justify-center flex-shrink-0 rounded text-gray-400 hover:text-gray-700 transition-colors duration-200"
            aria-expanded={expanded}
            aria-disabled={onCurrentPath || undefined}
            aria-label={`Toggle ${agent.name}`}
            title={
              onCurrentPath
                ? "On the current agent's path — stays expanded"
                : undefined
            }
          >
            <svg
              className={`w-3 h-3 transition-transform ${expanded ? "rotate-90" : ""}`}
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
        ) : (
          <span className="w-4 h-4 flex-shrink-0" aria-hidden="true" />
        )}
        {isArchived ? (
          <div
            className="flex items-center gap-2 min-w-0 flex-1 py-2 pr-3"
            title="Archived — restore this agent to open its chat"
          >
            {label}
          </div>
        ) : (
          <Link
            to={`/space/${spaceSlug}/agent/${encodeURIComponent(agent.name)}`}
            className="flex items-center gap-2 min-w-0 flex-1 py-2 pr-3"
          >
            {label}
          </Link>
        )}
        {isArchived && (
          <button
            type="button"
            onClick={() =>
              unarchiveAgent(agent.name, agent.space_id, null, (err) =>
                setRestoreError(restoreErrorMessage(err)),
              )
            }
            className="mr-2 rounded border border-gray-300 px-2 py-0.5 text-xs text-gray-600 hover:bg-gray-200 opacity-0 group-hover:opacity-100 transition-opacity"
            aria-label={`Restore ${agent.name}`}
            title="Restore agent"
          >
            Restore
          </button>
        )}
      </div>
      {restoreError && (
        <p role="alert" className="pl-3 py-0.5 text-xs text-red-600">
          {restoreError}
        </p>
      )}
      {hasChildren && expanded && (
        <ul className="space-y-1">
          {directChildren.map((child) => (
            <AgentTreeRow
              key={child.agent.name}
              node={child}
              depth={depth + 1}
              location={location}
              spaceSlug={spaceSlug}
              spaceId={spaceId}
              ancestors={ancestors}
              openGroups={openGroups}
            />
          ))}
          {!isArchived && archivedChildren.length > 0 && (
            <ArchivedGroup
              nodes={archivedChildren}
              depth={depth + 1}
              location={location}
              spaceSlug={spaceSlug}
              spaceId={spaceId}
              nodeKey={nodeKey}
              ancestors={ancestors}
              openGroups={openGroups}
              toggleLabel={`Toggle archived children of ${agent.name}`}
            />
          )}
        </ul>
      )}
    </li>
  );
}

/**
 * A collapsible space row: header (name + agent count) that expands to
 * the space's agent tree, plus archive. Clicking the name navigates to
 * `/space/:slug`; the chevron toggles the agent list.
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
  const selected = isSpaceActive(location, spaceBase);
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
