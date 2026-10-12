/**
 * Tests for the sidebar tree's pure helpers.
 *
 * The sidebar's own tests drive these through the rendered tree; this file
 * pins the derivations directly, including the cases the render cannot show
 * (an agent the tree does not contain, a name that needs decoding).
 */
import { describe, it, expect } from "vitest";
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
  nodePath,
  spaceNodeKey,
} from "./agentTree";

const agent = (name, parentName = null) => ({
  name,
  parentName,
  space_id: 1,
});

const archivedAgent = (name, parentName = null) => ({
  ...agent(name, parentName),
  archived: true,
});

describe("buildAgentTree", () => {
  it("nests children under their parent, alphabetized, and roots on top", () => {
    const tree = buildAgentTree([
      agent("zulu"),
      agent("alpha"),
      agent("beta", "zulu"),
      agent("aardvark", "zulu"),
    ]);

    // Roots alphabetized; the child lands under its parent, alphabetized too.
    expect(tree.map((n) => n.agent.name)).toEqual(["alpha", "zulu"]);
    expect(tree[1].children.map((n) => n.agent.name)).toEqual([
      "aardvark",
      "beta",
    ]);
  });

  it("treats an agent whose parent is not in the list as a root", () => {
    // The listing can carry an orphan (its parent row is gone); dropping it
    // would hide an agent the user can still open, so it renders at top level.
    const tree = buildAgentTree([agent("orphan", "missing-parent")]);

    expect(tree.map((n) => n.agent.name)).toEqual(["orphan"]);
  });

  it("builds an empty tree for a listing the sidebar does not have", () => {
    // `state.agents` is null before the lobby's first push arrives, and the
    // tree has to render then too.
    expect(buildAgentTree(null)).toEqual([]);
  });
});

describe("currentAgentName", () => {
  const location = (pathname) => ({ pathname });

  it("reads the agent the route names, decoding the link's encoding", () => {
    expect(
      currentAgentName(
        location("/space/my-space/agent/clever%20fox"),
        "my-space",
      ),
    ).toBe("clever fox");
  });

  it("is null when the route names no agent", () => {
    for (const pathname of [
      "/space/my-space",
      "/spaces",
      "/space/my-space/agent",
      "/space/other-space/agent/fox",
      "/space/my-space/agent/fox/messages",
    ]) {
      expect(currentAgentName(location(pathname), "my-space")).toBeNull();
    }
  });

  it("is null rather than throwing on a path that cannot be decoded", () => {
    // A truncated percent-escape is not valid UTF-8: the sidebar must survive
    // a URL the browser could not have produced.
    expect(
      currentAgentName(location("/space/my-space/agent/%E0%A4%A"), "my-space"),
    ).toBeNull();
  });
});

describe("nodePath", () => {
  it("returns the nodes from a root down to the named one", () => {
    const tree = buildAgentTree([
      agent("root"),
      agent("mid", "root"),
      agent("deep", "mid"),
      agent("other"),
    ]);

    expect(nodePath(tree, "deep").map((n) => n.agent.name)).toEqual([
      "root",
      "mid",
      "deep",
    ]);
    expect(nodePath(tree, "not-in-this-space")).toBeNull();
  });
});

describe("ancestorNames", () => {
  it("returns the path to a node, and nothing for an agent it lacks", () => {
    const tree = buildAgentTree([
      agent("root"),
      agent("mid", "root"),
      agent("deep", "mid"),
      agent("other"),
    ]);

    expect(ancestorNames(tree, "deep")).toEqual(new Set(["root", "mid"]));
    expect(ancestorNames(tree, "root")).toEqual(new Set());
    expect(ancestorNames(tree, "not-in-this-space")).toBe(NO_ANCESTORS);
  });
});

describe("ancestorGroupKeys", () => {
  it("names nothing when the path stays outside the Archived groups", () => {
    const tree = buildAgentTree([
      agent("root"),
      agent("mid", "root"),
      agent("deep", "mid"),
    ]);

    expect(ancestorGroupKeys(1, tree, "deep")).toEqual(new Set());
    expect(ancestorGroupKeys(1, tree, "not-in-this-space")).toBe(
      NO_ARCHIVED_GROUPS,
    );
  });

  it("names the group an archived current agent is nested in", () => {
    // An archived child of an active parent renders inside that parent's
    // `Archived (N)` group, so the group has to open for the agent to show.
    const tree = buildAgentTree([
      agent("parent"),
      archivedAgent("old", "parent"),
    ]);

    expect(ancestorGroupKeys(1, tree, "old")).toEqual(
      new Set([archivedGroupKey(agentNodeKey(1, "parent"))]),
    );
  });

  it("names the space's group when the current agent is an archived root", () => {
    const tree = buildAgentTree([archivedAgent("old-root")]);

    expect(ancestorGroupKeys(1, tree, "old-root")).toEqual(
      new Set([archivedGroupKey(spaceNodeKey(1))]),
    );
  });

  it("stops at the outermost group for a descendant of an archived node", () => {
    // An archived node renders its children directly, so only the group its
    // own root sits in has to open — there is no second group below it.
    const tree = buildAgentTree([
      archivedAgent("old-root"),
      archivedAgent("old-child", "old-root"),
    ]);

    expect(ancestorGroupKeys(1, tree, "old-child")).toEqual(
      new Set([archivedGroupKey(spaceNodeKey(1))]),
    );
  });
});

describe("node keys and archived counts", () => {
  it("keys a row, a group and a space into disjoint namespaces", () => {
    expect(agentNodeKey(7, "fox")).toBe("a:7:fox");
    expect(spaceNodeKey(7)).toBe("space:7");
    expect(archivedGroupKey(agentNodeKey(7, "fox"))).toBe("g:a:7:fox");
    expect(archivedGroupKey(spaceNodeKey(7))).toBe("g:space:7");
  });

  it("cannot be made to collide by an agent named after a group", () => {
    // An agent named `fox:archived` in space 7 used to spell the same key as
    // the `Archived (N)` group under the agent named `fox`, so opening one
    // opened the other. The prefixes are what rules that out, whatever the
    // agent is called.
    const keys = [
      agentNodeKey(7, "fox"),
      agentNodeKey(7, "fox:archived"),
      archivedGroupKey(agentNodeKey(7, "fox")),
      archivedGroupKey(agentNodeKey(7, "fox:archived")),
      spaceNodeKey(7),
      archivedGroupKey(spaceNodeKey(7)),
    ];

    expect(new Set(keys).size).toBe(keys.length);
  });

  it("counts a subtree's archived nodes including the node itself", () => {
    const tree = buildAgentTree([agent("old"), agent("older", "old")]);

    expect(countArchived(tree)).toBe(2);
    expect(countArchived([])).toBe(0);
    expect(countArchived(null)).toBe(0);
  });
});
