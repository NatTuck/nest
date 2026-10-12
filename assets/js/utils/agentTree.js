/**
 * Pure helpers for the sidebar's agent tree.
 *
 * Split out of `SidebarSpaceRow.jsx` (which renders the tree) so the
 * derivations can be tested on their own: the cases that matter here — an
 * agent the tree does not contain, a route segment that cannot be decoded —
 * are hard to reach through the rendered sidebar and trivial to state
 * directly. Nothing here touches React or the store.
 */

// A stable empty set, so a space with no selected agent hands every row the
// same (unchanged) prop.
export const NO_ANCESTORS = new Set();

// Likewise for the groups to force open: usually there are none.
export const NO_ARCHIVED_GROUPS = new Set();

/**
 * The store key for one agent row's disclosure. Agent names are unique within
 * a space, not across spaces, so the space id scopes it.
 *
 * The `a:` prefix keeps node keys out of the `g:` namespace of
 * `archivedGroupKey`: an agent named `x:archived` under space 1 must not be
 * able to spell out the group key hanging off its own space (`g:a:1:x`).
 */
export function agentNodeKey(spaceId, name) {
  return `a:${spaceId}:${name}`;
}

/**
 * The store key for a space row's own `Archived (N)` group, which holds that
 * space's archived roots. The space row itself is not a disclosure node (its
 * expansion follows the route), so this key exists only as a group's parent.
 */
export function spaceNodeKey(spaceId) {
  return `space:${spaceId}`;
}

/**
 * The store key for the `Archived (N)` group rendered under the node with
 * key `parentKey`. The `g:` prefix is what makes a group key unmistakably
 * different from the node key it hangs off.
 */
export function archivedGroupKey(parentKey) {
  return `g:${parentKey}`;
}

/**
 * Build a tree from a flat agents list. Each agent's
 * `parentName` is the parent's readable identifier
 * (or `null` for roots). The helper returns
 * `[{ agent, children: [...] }, ...]` for roots, with
 * children recursively nested. Siblings are alphabetized.
 */
export function buildAgentTree(agents) {
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
 * The agent named by the current route, or `null`. The rows link with
 * `encodeURIComponent(agent.name)`, so the segment is decoded back. The slug
 * is the *encoded* one: the pathname carries the encoded form, so anything
 * else would not match a slug the browser had to escape.
 */
export function currentAgentName(location, spaceSlug) {
  const prefix = `/space/${spaceSlug}/agent/`;
  if (!location.pathname.startsWith(prefix)) return null;

  const rest = location.pathname.slice(prefix.length);
  if (rest === "" || rest.includes("/")) return null;

  try {
    return decodeURIComponent(rest);
  } catch {
    return null;
  }
}

/**
 * The nodes from a root down to the one named `name`, inclusive, or `null`
 * when the tree does not contain that agent. The two "keep the current agent
 * visible" derivations below are both read off this path.
 */
export function nodePath(nodes, name) {
  const walk = (nodes, path) => {
    for (const node of nodes) {
      const next = [...path, node];
      if (node.agent.name === name) return next;
      const found = walk(node.children, next);
      if (found) return found;
    }
    return null;
  };

  return walk(nodes, []);
}

/**
 * The names of the nodes on the path from a root to `name`, excluding `name`
 * itself — the rows that have to stay open for the current agent to be
 * visible. Empty when the tree does not contain that agent.
 */
export function ancestorNames(nodes, name) {
  const path = nodePath(nodes, name);
  if (!path) return NO_ANCESTORS;

  return new Set(path.slice(0, -1).map((node) => node.agent.name));
}

/**
 * The `Archived (N)` group keys that have to be open for the node named
 * `name` to be visible. An archived node renders inside the group its active
 * parent draws (or its space's, when it is an archived root), so without this
 * an archived current agent would sit behind a collapsed group — exactly what
 * pinning the chain promises not to happen. An archived node's own
 * descendants render directly, so at most one group per level is named.
 */
export function ancestorGroupKeys(spaceId, nodes, name) {
  const path = nodePath(nodes, name);
  if (!path) return NO_ARCHIVED_GROUPS;

  const keys = new Set();
  if (path[0].agent.archived === true) {
    keys.add(archivedGroupKey(spaceNodeKey(spaceId)));
  }
  for (let i = 1; i < path.length; i += 1) {
    const parent = path[i - 1].agent;
    const child = path[i].agent;
    if (parent.archived !== true && child.archived === true) {
      keys.add(archivedGroupKey(agentNodeKey(spaceId, parent.name)));
    }
  }
  return keys;
}

/**
 * Count every archived node in a built subtree (the node itself plus
 * all of its descendants). Drives the `Archived (N)` group labels.
 */
export function countArchived(nodes) {
  return (nodes || []).reduce(
    (total, node) => total + 1 + countArchived(node.children),
    0,
  );
}
