/**
 * The rows inside a space's sidebar entry: the recursive agent rows, and the
 * `Archived (N)` groups that hold stopped agents. Extracted from
 * `SidebarSpaceRow` so the space row (its links, its disclosure, its archive
 * button) and the tree below it can each stay under the source-line cap.
 *
 * Both components are recursive through each other: an active agent's archived
 * children render as an `ArchivedGroup`, and that group renders `AgentTreeRow`s.
 * They live in one file for that reason.
 */

import { useState } from "react";
import { Link } from "react-router-dom";
import { unarchiveAgent } from "../channels";
import { useStore } from "../store";
import {
  agentNodeKey,
  archivedGroupKey,
  countArchived,
} from "../utils/agentTree";
import { StatusDot } from "./StatusDot";

/**
 * The full fact behind a row's job count (#174/#175). The parens are compact, so
 * the tooltip and the accessible name say what the number counts. "shell jobs"
 * rather than "background jobs" because the count includes a foreground
 * `shell-cmd` call while it runs.
 */
function runningJobsLabel(count) {
  return `${count} shell ${count === 1 ? "job" : "jobs"} running`;
}

/**
 * The same for a row's child count. A row can show both numbers, one after the
 * other (`name (2) (3)`), and without its own label the second is
 * indistinguishable from the first to a screen reader — and separable only by
 * colour to everyone else.
 */
function directChildrenLabel(count) {
  return `${count} child ${count === 1 ? "agent" : "agents"}`;
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
export function ArchivedGroup({
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
export function AgentTreeRow({
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

  // The agent's running background jobs (#175). An archived agent has none —
  // its process is stopped — so its row shows no count even when the copy of
  // the row kept one from before it was archived.
  const runningJobs = isArchived ? 0 : (agent.runningJobs ?? 0);

  const label = (
    <>
      <StatusDot
        status={joining ? "connecting" : agent.status}
        className="w-2 h-2"
      />
      <span className="truncate text-sm font-medium">{agent.name}</span>
      {runningJobs > 0 && (
        <span
          className="text-xs font-medium text-amber-600 ml-1"
          role="img"
          aria-label={runningJobsLabel(runningJobs)}
        >
          ({runningJobs})
        </span>
      )}
      {directChildren.length > 0 && (
        <span
          className="text-xs text-gray-400 ml-1"
          role="img"
          aria-label={directChildrenLabel(directChildren.length)}
          title={directChildrenLabel(directChildren.length)}
        >
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
            title={runningJobs > 0 ? runningJobsLabel(runningJobs) : undefined}
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
