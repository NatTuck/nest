/**
 * Sidebar test — focused coverage on the agent tree builder
 * and the tree render. The rest of the sidebar is exercised
 * by the App-level ChatPage tests; here we assert just the
 * behaviour introduced by sub-agent delegation.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, act, fireEvent } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

import { Sidebar } from "./Sidebar";
import { useStore } from "../store";
import { joinLobby } from "../channels";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  connectSocket,
  captureNextPush,
} from "../__mocks__/phoenix";

function withStore(agents) {
  // Agents are grouped under a space row in the sidebar. Seed a
  // single space (id 1, slug "my-space") and default each agent's
  // `space_id` to it. Tests that assert on the agent tree render at
  // `/space/my-space` so the space row is route-selected (expanded).
  useStore.setState({
    agents: agents.map((a) => ({ ...a, space_id: a.space_id ?? 1 })),
    archivedAgents: [],
    spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
  });
}

function clearAgents() {
  useStore.setState({ agents: null, archivedAgents: [], spaces: [] });
}

beforeEach(() => {
  resetMockSocket();
  // The tree's disclosure lives in the store (see `expandedTreeNodes`), so it
  // outlives a test the way `agents`/`spaces` would: every test starts with
  // every node collapsed.
  useStore.setState({ expandedTreeNodes: {} });
  // Connect socket and join lobby so the click reaches the
  // push path. The vite alias resolves "phoenix" to the
  // mock in test mode, so joinLobby() uses the mock channel
  // layer. The mock channel is set up with no autoInit so
  // joinLobby() doesn't trigger a store update — the agents
  // list is set explicitly by each test's withStore() call.
  connectSocket();
  setNextJoinResult("lobby", {});
  joinLobby();
});

afterEach(() => {
  resetMockSocket();
});

describe("Sidebar tree", () => {
  it("renders a flat agents list as roots", () => {
    act(() => {
      withStore([
        { name: "alpha", parentId: null, parentName: null, depth: 0 },
        { name: "bravo", parentId: null, parentName: null, depth: 0 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("bravo")).toBeInTheDocument();
  });

  it("nests a child under its parent", () => {
    act(() => {
      withStore([
        { name: "parent", parentId: null, parentName: null, depth: 0 },
        {
          name: "child-of-parent",
          parentId: 1,
          parentName: "parent",
          depth: 1,
        },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("parent")).toBeInTheDocument();

    // A node starts collapsed, so its child is hidden until expanded.
    expect(screen.queryByText("child-of-parent")).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle parent" }));
    });

    expect(screen.getByText("child-of-parent")).toBeInTheDocument();
  });

  it("expands one level at a time, never a whole subtree", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "child", parentId: 1, parentName: "root", depth: 1 },
        { name: "grandchild", parentId: 1, parentName: "child", depth: 2 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // Every node starts collapsed: only the root is visible.
    expect(screen.getByText("root")).toBeInTheDocument();
    expect(screen.queryByText("child")).not.toBeInTheDocument();
    expect(screen.queryByText("grandchild")).not.toBeInTheDocument();

    const rootToggle = screen.getByRole("button", { name: "Toggle root" });
    expect(rootToggle).toHaveAttribute("aria-expanded", "false");

    // Expanding the root reveals its direct children only — the
    // grandchild stays behind the child's own collapsed toggle.
    act(() => {
      fireEvent.click(rootToggle);
    });

    expect(screen.getByText("child")).toBeInTheDocument();
    expect(screen.queryByText("grandchild")).not.toBeInTheDocument();
    expect(rootToggle).toHaveAttribute("aria-expanded", "true");

    // An interior node expands independently of its parent.
    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle child" }));
    });

    expect(screen.getByText("grandchild")).toBeInTheDocument();

    // Collapsing the root hides its whole subtree again.
    act(() => {
      fireEvent.click(rootToggle);
    });

    expect(screen.getByText("root")).toBeInTheDocument();
    expect(screen.queryByText("child")).not.toBeInTheDocument();
    expect(screen.queryByText("grandchild")).not.toBeInTheDocument();
    expect(rootToggle).toHaveAttribute("aria-expanded", "false");
  });

  it("expands exactly the current agent's ancestors, and nothing else", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "mid", parentId: 1, parentName: "root", depth: 1 },
        { name: "deep", parentId: 1, parentName: "mid", depth: 2 },
        { name: "other", parentId: null, parentName: null, depth: 0 },
        { name: "other-child", parentId: 1, parentName: "other", depth: 1 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/deep"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The selected agent is visible without a click: its whole ancestor chain
    // opened for it.
    expect(screen.getByText("deep")).toBeInTheDocument();

    // The space row is the top of that chain, so it is open too.
    expect(
      screen.getByRole("button", { name: "Toggle My Space" }),
    ).toHaveAttribute("aria-expanded", "true");

    // ...and exactly the chain: the sibling branch is still closed, so its
    // child is not rendered at all.
    const otherToggle = screen.getByRole("button", { name: "Toggle other" });
    expect(otherToggle).toHaveAttribute("aria-expanded", "false");
    expect(otherToggle).not.toHaveAttribute("aria-disabled");
    expect(screen.queryByText("other-child")).not.toBeInTheDocument();

    expect(
      screen
        .getAllByRole("button", { expanded: true })
        .map((button) => button.getAttribute("aria-label")),
    ).toEqual(["Toggle My Space", "Toggle root", "Toggle mid"]);
  });

  it("matches the route's encoded slug when pinning the chain", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "deep",
            space_id: 1,
            parentId: 1,
            parentName: "root",
            depth: 1,
          },
        ],
        archivedAgents: [],
        spaces: [{ id: 1, slug: "my space", name: "My Space" }],
      });
    });

    // A slug with a space in it is spelled `my%20space` in the pathname, which
    // is what the tree reads. Comparing against the raw slug would recognize
    // neither the space nor the agent, and the agent the route names would be
    // left behind a collapsed row — the one thing the pin promises not to do.
    render(
      <MemoryRouter initialEntries={["/space/my%20space/agent/deep"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(
      screen.getByRole("button", { name: "Toggle My Space" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("button", { name: "Toggle root" })).toHaveAttribute(
      "aria-expanded",
      "true",
    );
    expect(screen.getByText("deep")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /deep/ })).toHaveAttribute(
      "href",
      "/space/my%20space/agent/deep",
    );
  });

  it("scopes a node's disclosure to its own space", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "child",
            space_id: 1,
            parentId: 1,
            parentName: "root",
            depth: 1,
          },
          {
            name: "root",
            space_id: 2,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "child",
            space_id: 2,
            parentId: 1,
            parentName: "root",
            depth: 1,
          },
        ],
        archivedAgents: [],
        spaces: [
          { id: 1, slug: "first", name: "First Space" },
          { id: 2, slug: "second", name: "Second Space" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/first"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    act(() => {
      fireEvent.click(
        screen.getByRole("button", { name: "Toggle Second Space" }),
      );
    });

    // Both spaces list an agent named `root` with a child named `child`, so
    // the two rows agree on everything but their space. The store key carries
    // the space id for exactly this reason: opening one must not open the
    // other.
    const [firstRoot, secondRoot] = screen.getAllByRole("button", {
      name: "Toggle root",
    });

    act(() => {
      fireEvent.click(firstRoot);
    });

    expect(firstRoot).toHaveAttribute("aria-expanded", "true");
    expect(secondRoot).toHaveAttribute("aria-expanded", "false");
    expect(screen.getAllByText("child")).toHaveLength(1);
  });

  it("keeps a group's disclosure apart from an agent named after it", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "root:archived",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "kid",
            space_id: 1,
            parentId: 1,
            parentName: "root:archived",
            depth: 1,
          },
        ],
        archivedAgents: [
          {
            name: "old-child",
            space_id: 1,
            parentId: 1,
            parentName: "root",
            depth: 1,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle root" }));
    });

    // Three separate things share this space: the agent `root`, the agent
    // `root:archived`, and the `Archived (1)` group hanging off `root`. The
    // group's key is derived from the row's, so the row named after it must
    // not be able to open it — the keys keep the two in separate namespaces.
    const groupToggle = screen.getByRole("button", {
      name: "Toggle archived children of root",
    });
    expect(groupToggle).toHaveAttribute("aria-expanded", "false");

    act(() => {
      fireEvent.click(
        screen.getByRole("button", { name: "Toggle root:archived" }),
      );
    });

    expect(groupToggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("old-child")).not.toBeInTheDocument();
  });

  it("keeps a subtree open when its ancestor is collapsed and expanded again", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "child", parentId: 1, parentName: "root", depth: 1 },
        { name: "grandchild", parentId: 1, parentName: "child", depth: 2 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle root" }));
    });
    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle child" }));
    });
    expect(screen.getByText("grandchild")).toBeInTheDocument();

    // Collapsing the root unmounts the whole subtree, child row included.
    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle root" }));
    });
    expect(screen.queryByText("grandchild")).not.toBeInTheDocument();

    // Re-opening it restores the subtree the user had opened: the child's
    // disclosure survived the unmount because it is store state, not row state.
    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle root" }));
    });
    expect(
      screen.getByRole("button", { name: "Toggle child" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("grandchild")).toBeInTheDocument();
  });

  it("does not let a click hide the current agent behind a collapsed ancestor", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "child", parentId: 1, parentName: "root", depth: 1 },
        { name: "deep", parentId: 1, parentName: "child", depth: 2 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/deep"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("deep")).toBeInTheDocument();

    // The chain is on the current agent's path, so its toggle cannot close it:
    // the route's agent stays visible (the toggle says why it is pinned open,
    // to the mouse and to a screen reader).
    const rootToggle = screen.getByRole("button", { name: "Toggle root" });
    expect(rootToggle).toHaveAttribute(
      "title",
      "On the current agent's path — stays expanded",
    );
    expect(rootToggle).toHaveAttribute("aria-disabled", "true");

    act(() => {
      fireEvent.click(rootToggle);
    });

    expect(screen.getByText("deep")).toBeInTheDocument();
    expect(rootToggle).toHaveAttribute("aria-expanded", "true");

    // The click is a no-op, not a deferred flip: writing the state it cannot
    // show would surface later, on a route where this row is free to move.
    expect(useStore.getState().expandedTreeNodes).toEqual({});

    // The same holds one level up: the space row is the top of the chain, so
    // collapsing it cannot hide the agent the route is on either. (It toggles
    // freely when the route is the space's own overview — nothing to lose.)
    const spaceToggle = screen.getByRole("button", { name: "Toggle My Space" });
    expect(spaceToggle).toHaveAttribute(
      "title",
      "Holds the current agent — stays expanded",
    );
    expect(spaceToggle).toHaveAttribute("aria-disabled", "true");

    act(() => {
      fireEvent.click(spaceToggle);
    });

    expect(screen.getByText("deep")).toBeInTheDocument();
    expect(spaceToggle).toHaveAttribute("aria-expanded", "true");
    expect(useStore.getState().expandedTreeNodes).toEqual({});

    // ...and that no-op is not a deferred flip either. This row's expansion is
    // component state derived from the route, so a click that stored "closed"
    // would surface the moment the route moved within this space: `selected`
    // stays true on the way to the space's own page, so nothing re-derives the
    // row and the user would land on a collapsed row for the space they are in.
    act(() => {
      fireEvent.click(screen.getByRole("link", { name: /^My Space/ }));
    });

    expect(
      screen.getByRole("button", { name: "Toggle My Space" }),
    ).toHaveAttribute("aria-expanded", "true");
  });

  it("lets a space row with no agent selected be collapsed", () => {
    act(() => {
      withStore([{ name: "root", parentId: null, parentName: null, depth: 0 }]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("root")).toBeInTheDocument();

    const spaceToggle = screen.getByRole("button", { name: "Toggle My Space" });
    expect(spaceToggle).toHaveAttribute("aria-expanded", "true");
    expect(spaceToggle).not.toHaveAttribute("title");
    expect(spaceToggle).not.toHaveAttribute("aria-disabled");

    act(() => {
      fireEvent.click(spaceToggle);
    });

    expect(spaceToggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("root")).not.toBeInTheDocument();
  });

  it("survives an agent path the browser could not have produced", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "child", parentId: 1, parentName: "root", depth: 1 },
      ]);
    });

    // A truncated percent-escape is not a valid UTF-8 sequence, so decoding it
    // throws. The tree reads the route to find the current agent, and a bad URL
    // must not take the whole sidebar down with it: the space row still renders
    // and nothing is expanded for an agent it cannot name.
    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/%E0%A4%A"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("My Space")).toBeInTheDocument();
    expect(screen.getByText("root")).toBeInTheDocument();
    expect(screen.queryByText("child")).not.toBeInTheDocument();
  });

  it("opens the Archived group holding an archived current agent", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "parent",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        archivedAgents: [
          {
            name: "old-child",
            space_id: 1,
            parentId: 1,
            parentName: "parent",
            depth: 1,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/old-child"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // An archived child of an active parent renders inside that parent's
    // `Archived (N)` group. The agent the route names is the one row the tree
    // promises to keep visible, so the group hiding it opens with the chain
    // above it — and the row it reveals is the one carrying the Restore button
    // the user needs.
    expect(
      screen.getByRole("button", {
        name: "Toggle archived children of parent",
      }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(
      screen.getByRole("button", { name: "Toggle parent" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("old-child")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /restore old-child/i }),
    ).toBeInTheDocument();
  });

  it("opens the space's Archived group for an archived current agent", () => {
    act(() => {
      useStore.setState({
        agents: [],
        archivedAgents: [
          {
            name: "old-root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
            archived: true,
          },
          {
            name: "old-mid",
            space_id: 1,
            parentId: 1,
            parentName: "old-root",
            depth: 1,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/old-mid"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // An archived root lives in the space's own `Archived (N)` group, so that
    // is the group pinned open here; its toggle is announced as pinned and a
    // click on it writes nothing. The chain continues inside the group, where
    // the archived rows render their children directly — the ancestor chain
    // reaches down there too, or a current agent one level deeper would still
    // be hidden.
    const groupToggle = screen.getByRole("button", {
      name: /toggle archived agents/i,
    });
    expect(groupToggle).toHaveAttribute("aria-expanded", "true");
    expect(groupToggle).toHaveAttribute("aria-disabled", "true");
    expect(
      screen.getByRole("button", { name: "Toggle old-root" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("old-mid")).toBeInTheDocument();

    act(() => {
      fireEvent.click(groupToggle);
    });

    expect(groupToggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("old-mid")).toBeInTheDocument();
    expect(useStore.getState().expandedTreeNodes).toEqual({});
  });

  it("starts a space row collapsed when its route is not open", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "root-a",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        archivedAgents: [],
        spaces: [
          { id: 1, slug: "first", name: "First Space" },
          { id: 2, slug: "second", name: "Second Space" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/second"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // Only the route's own space row opens; the other stays closed.
    expect(screen.queryByText("root-a")).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(
        screen.getByRole("button", { name: "Toggle First Space" }),
      );
    });

    expect(screen.getByText("root-a")).toBeInTheDocument();
  });

  it("moves the expanded space row with the route", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "root-a",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "root-b",
            space_id: 2,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        archivedAgents: [],
        spaces: [
          { id: 1, slug: "first", name: "First Space" },
          { id: 2, slug: "second", name: "Second Space" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/first"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("root-a")).toBeInTheDocument();
    expect(screen.queryByText("root-b")).not.toBeInTheDocument();

    // The expansion follows the route rather than freezing at mount, so
    // navigating away closes the row we left instead of leaving two open.
    act(() => {
      fireEvent.click(screen.getByRole("link", { name: /^Second Space/ }));
    });

    expect(screen.getByText("root-b")).toBeInTheDocument();
    expect(screen.queryByText("root-a")).not.toBeInTheDocument();
  });

  it("renders no chevron for leaf nodes", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "leaf", parentId: 1, parentName: "root", depth: 1 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle root" }));
    });

    expect(screen.getByText("leaf")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Toggle leaf" }),
    ).not.toBeInTheDocument();
  });

  it("renders archived agents in a collapsed, nested 'Archived' group", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "active-root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        archivedAgents: [
          {
            name: "old-parent",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
            archived: true,
          },
          {
            name: "old-child",
            space_id: 1,
            parentId: 1,
            parentName: "old-parent",
            depth: 1,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("active-root")).toBeInTheDocument();

    // Collapsed by default: the archived names are hidden.
    expect(screen.queryByText("old-parent")).not.toBeInTheDocument();
    expect(screen.queryByText("old-child")).not.toBeInTheDocument();

    const toggle = screen.getByRole("button", {
      name: /toggle archived agents/i,
    });
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    act(() => {
      fireEvent.click(toggle);
    });

    // Expanded: the archived roots render, still one level at a time —
    // the archived child stays behind its parent's own toggle.
    expect(screen.getByText("old-parent")).toBeInTheDocument();
    expect(screen.queryByText("old-child")).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(
        screen.getByRole("button", { name: "Toggle old-parent" }),
      );
    });

    expect(screen.getByText("old-child")).toBeInTheDocument();
  });

  it("nests an archived child under its active parent, collapsed", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "parent",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        archivedAgents: [
          {
            name: "old-child",
            space_id: 1,
            parentId: 1,
            parentName: "parent",
            depth: 1,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("parent")).toBeInTheDocument();

    // The parent starts collapsed, so its `Archived (1)` group is not
    // rendered at all until the parent is expanded.
    expect(
      screen.queryByRole("button", {
        name: "Toggle archived children of parent",
      }),
    ).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle parent" }));
    });

    // The archived child stays nested under the active parent and is
    // hidden behind that parent's collapsed `Archived (1)` group.
    expect(screen.queryByText("old-child")).not.toBeInTheDocument();

    const toggle = screen.getByRole("button", {
      name: "Toggle archived children of parent",
    });
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    act(() => {
      fireEvent.click(toggle);
    });

    expect(screen.getByText("old-child")).toBeInTheDocument();
  });

  it("nests archived descendants inside an archived subtree", () => {
    act(() => {
      useStore.setState({
        agents: [],
        archivedAgents: [
          {
            name: "old-root",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
            archived: true,
          },
          {
            name: "old-mid",
            space_id: 1,
            parentId: 1,
            parentName: "old-root",
            depth: 1,
            archived: true,
          },
          {
            name: "old-leaf",
            space_id: 1,
            parentId: 2,
            parentName: "old-mid",
            depth: 2,
            archived: true,
          },
        ],
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByText("old-root")).not.toBeInTheDocument();

    const toggle = screen.getByRole("button", {
      name: /toggle archived agents/i,
    });
    act(() => {
      fireEvent.click(toggle);
    });

    expect(screen.getByText("old-root")).toBeInTheDocument();
    expect(screen.queryByText("old-mid")).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle old-root" }));
    });

    expect(screen.getByText("old-mid")).toBeInTheDocument();
    expect(screen.queryByText("old-leaf")).not.toBeInTheDocument();

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "Toggle old-mid" }));
    });

    expect(screen.getByText("old-leaf")).toBeInTheDocument();
  });

  it("shows the child count next to a parent with children", () => {
    act(() => {
      withStore([
        { name: "root", parentId: null, parentName: null, depth: 0 },
        { name: "a", parentId: 1, parentName: "root", depth: 1 },
        { name: "b", parentId: 1, parentName: "root", depth: 1 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("(2)")).toBeInTheDocument();
  });

  it("treats an agent whose parentName doesn't resolve as a root", () => {
    // An orphan agent whose parent row is gone but the
    // listing still has them. We want them visible at top
    // level rather than dropped silently.
    act(() => {
      withStore([
        { name: "alive", parentId: null, parentName: null, depth: 0 },
        {
          name: "orphan",
          parentId: 99,
          parentName: "missing-parent",
          depth: 1,
        },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("alive")).toBeInTheDocument();
    expect(screen.getByText("orphan")).toBeInTheDocument();
  });

  it("renders without crashing when a child has no children (a deep root)", () => {
    // Covers the `children.length > 0` branch (false) and
    // the (!isLeaf) early-out in the tree-row link rendering.
    act(() => {
      withStore([{ name: "solo", parentId: null, parentName: null, depth: 0 }]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("solo")).toBeInTheDocument();
  });

  it("renders the active route's agent with the highlighted styling", () => {
    act(() => {
      withStore([
        { name: "alpha", parentId: null, parentName: null, depth: 0 },
        { name: "bravo", parentId: null, parentName: null, depth: 0 },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/bravo"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The highlighted link carries `border-blue-200` (vs.
    // the default `border-transparent`); checking via
    // className is brittle, so just assert that the active
    // agent's link is reachable through the rendered tree.
    expect(screen.getByText("bravo")).toBeInTheDocument();
    expect(screen.getByText("alpha")).toBeInTheDocument();
  });

  it("highlights the space whose agent is open, not the first space", () => {
    act(() => {
      useStore.setState({
        agents: [
          {
            name: "first-agent",
            space_id: 1,
            parentId: null,
            parentName: null,
            depth: 0,
          },
          {
            name: "bob",
            space_id: 2,
            parentId: null,
            parentName: null,
            depth: 0,
          },
        ],
        spaces: [
          { id: 1, slug: "first", name: "First Space" },
          { id: 2, slug: "second", name: "Second Space" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/second/agent/bob"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The row's highlight class lives on the div wrapping the
    // space-name link; the link is its direct child.
    const firstLink = screen.getByRole("link", { name: /^First Space/ });
    const secondLink = screen.getByRole("link", { name: /^Second Space/ });
    expect(firstLink.parentElement.className).not.toMatch(/bg-blue-50/);
    expect(secondLink.parentElement.className).toMatch(/bg-blue-50/);
  });

  it("highlights no space row when not inside a space route", () => {
    act(() => {
      useStore.setState({
        agents: [],
        spaces: [
          { id: 1, slug: "first", name: "First Space" },
          { id: 2, slug: "second", name: "Second Space" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/spaces"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    const firstLink = screen.getByRole("link", { name: /^First Space/ });
    const secondLink = screen.getByRole("link", { name: /^Second Space/ });
    expect(firstLink.parentElement.className).not.toMatch(/bg-blue-50/);
    expect(secondLink.parentElement.className).not.toMatch(/bg-blue-50/);
  });

  it("renders a streaming status dot (green pulse) for streaming agents", () => {
    act(() => {
      withStore([
        {
          name: "live",
          parentId: null,
          parentName: null,
          depth: 0,
          status: "streaming",
        },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The streaming dot is reachable through `role="button"`
    // parent (no aria-label on the dot itself). Use the
    // container to assert the className includes the
    // streaming indicator.
    const dot = document.querySelector(".animate-pulse");
    expect(dot).toBeInTheDocument();
  });

  it("renders an executing_tools amber pulse dot", () => {
    act(() => {
      withStore([
        {
          name: "tools",
          parentId: null,
          parentName: null,
          depth: 0,
          status: "executing_tools",
        },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    const dot = document.querySelector(".animate-pulse.bg-amber-500");
    expect(dot).toBeInTheDocument();
  });

  it("highlights the '/about' link when the route starts with /about", () => {
    act(() => {
      withStore([]);
    });

    render(
      <MemoryRouter initialEntries={["/about/details"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    const about = screen.getByRole("link", { name: /about/i });
    // The "About" link carries the bg-blue-50 active class
    // when the route starts with `/about`.
    expect(about.className).toMatch(/bg-blue-50/);
  });

  it("shows the Providers link to admins", () => {
    act(() => {
      useStore.setState({
        currentUser: { id: 1, username: "admin", is_admin: true },
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(
      screen.getByRole("link", { name: /providers/i }),
    ).toBeInTheDocument();
  });

  it("hides the Providers link from non-admins", () => {
    act(() => {
      useStore.setState({
        currentUser: { id: 2, username: "bob", is_admin: false },
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByRole("link", { name: /providers/i })).toBeNull();
  });

  it("renders gracefully when state.agents is null (defensive)", () => {
    // The lobby initializes `state.agents` to `[]` but a
    // race or stale state could leave it `null`. The sidebar
    // reads `spaces`/`agents` defensively so it must handle
    // this without crashing.
    act(() => {
      clearAgents();
    });

    const { container } = render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    // With no spaces, the sidebar shows the empty state.
    expect(container.textContent).toContain("No spaces yet");
  });
});

describe("Sidebar space overview", () => {
  it("links the space's own row to its overview, and marks it current there", () => {
    act(() => {
      withStore([{ name: "root", parentId: null, parentName: null, depth: 0 }]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space/agent/root"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The overview is the space's page, so it hangs off the space's own row
    // rather than an agent's header: a space whose blueprint names an `rpg`
    // Main View has no agent header at all, so a header link would leave that
    // space's environment unreachable from its main screen.
    const overview = screen.getByRole("link", {
      name: "Overview of My Space",
    });
    expect(overview).toHaveAttribute("href", "/space/my-space/overview");
    // The space's name still goes to its Main View.
    expect(screen.getByRole("link", { name: /^My Space/ })).toHaveAttribute(
      "href",
      "/space/my-space",
    );
    // An agent's chat is open, so the overview is not the current page.
    expect(overview).not.toHaveAttribute("aria-current");

    act(() => {
      fireEvent.click(overview);
    });

    // On the overview it says so, which is also how the row stays selected
    // through a route that has no agent in it.
    expect(
      screen.getByRole("link", { name: "Overview of My Space" }),
    ).toHaveAttribute("aria-current", "page");
  });
});

describe("Sidebar broken-agent rows", () => {
  // A persisted agent whose model no longer resolves has no live process,
  // so nothing broadcasts a status for it. It still gets a flat-list row —
  // the visibility query lists persisted rows on purpose, so the user can
  // click through and repair it — and the lobby stamps the server's
  // `model_missing` onto that row (see `applyAgentStatuses`). The sidebar
  // therefore renders one ordinary row with a red dot, not a separate
  // "Needs Repair" group.

  it("renders no 'Needs Repair' group", () => {
    act(() => {
      withStore([]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByText(/needs repair/i)).toBeNull();
  });

  it("renders a stamped broken agent as a static red dot with a tooltip", () => {
    act(() => {
      withStore([
        { name: "ghost-agent", status: "model_missing" },
        { name: "second-ghost", status: "model_missing" },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByText(/needs repair/i)).toBeNull();

    const dots = screen.getAllByRole("img", { name: "Model missing" });
    expect(dots.length).toBe(2);
    for (const dot of dots) {
      expect(dot.className).toContain("bg-red-500");
      expect(dot.className).not.toContain("animate-pulse");
      expect(dot.getAttribute("title")).toBe("Model missing");
    }
  });

  it("keeps the broken agent reachable on its space-scoped chat path", () => {
    act(() => {
      withStore([{ name: "ghost-agent", status: "model_missing" }]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    const link = screen.getByRole("link", { name: /ghost-agent/ });
    expect(link.getAttribute("href")).toBe("/space/my-space/agent/ghost-agent");
  });

  it("shows a healthy agent's dot unchanged next to a broken one", () => {
    act(() => {
      withStore([
        { name: "ghost-agent", status: "model_missing" },
        { name: "healthy", status: "streaming" },
      ]);
    });

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(
      screen.getByRole("img", { name: "Model missing" }),
    ).toBeInTheDocument();
    const healthy = screen.getByRole("img", { name: "Streaming" });
    expect(healthy.className).toContain("bg-green-500");
    expect(healthy.className).toContain("animate-pulse");
  });

  it("scopes a broken agent to its own space", () => {
    act(() => {
      withStore([]);
      useStore.setState({
        spaces: [
          { id: 1, slug: "space-a", name: "Space A" },
          { id: 2, slug: "space-b", name: "Space B" },
        ],
        agents: [
          { name: "broken-a", space_id: 1, status: "model_missing" },
          { name: "broken-b", space_id: 2, status: "model_missing" },
        ],
      });
    });

    render(
      <MemoryRouter initialEntries={["/space/space-a"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // Space A is the route-selected/expanded space, so its broken agent
    // renders with the correct space-scoped path.
    const linkA = screen.getByRole("link", { name: /broken-a/ });
    expect(linkA.getAttribute("href")).toBe("/space/space-a/agent/broken-a");

    // Space B is collapsed, so its broken agent is not rendered.
    expect(screen.queryByText(/broken-b/i)).toBeNull();
  });
});

describe("Sidebar space archiving", () => {
  it("renders an Archive button on each active space row", async () => {
    act(() => {
      useStore.setState({
        spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
        archivedSpaces: [],
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    const button = screen.getByRole("button", { name: /archive my space/i });
    expect(button).toBeInTheDocument();
  });

  it("clicking Archive pushes archive_space with the space id", async () => {
    act(() => {
      useStore.setState({
        spaces: [{ id: 7, slug: "my-space", name: "My Space" }],
        archivedSpaces: [],
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    const pushPromise = captureNextPush("lobby", "archive_space");
    act(() => {
      screen.getByRole("button", { name: /archive my space/i }).click();
    });

    const payload = await pushPromise;
    expect(payload).toEqual({ space_id: 7 });
  });

  it("renders archived spaces in the Archived section once expanded", () => {
    act(() => {
      useStore.setState({
        spaces: [{ id: 1, slug: "active", name: "Active Space" }],
        archivedSpaces: [{ id: 2, slug: "gone", name: "Gone Space" }],
        archivedCollapsed: true,
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("Archived")).toBeInTheDocument();

    // Collapsed by default — the space rows are hidden until the
    // header is clicked.
    expect(screen.queryByText("Gone Space")).toBeNull();

    act(() => {
      screen.getByRole("button", { name: /toggle archived spaces/i }).click();
    });

    expect(screen.getByText("Gone Space")).toBeInTheDocument();
    // The archived space is not in the active list.
    expect(screen.getByRole("link", { name: /gone space/i })).toBeTruthy();
  });

  it("archived section is collapsed by default", () => {
    act(() => {
      useStore.setState({
        spaces: [],
        archivedSpaces: [{ id: 9, slug: "gone", name: "Gone Space" }],
        archivedCollapsed: true,
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    // Header renders but the space row is hidden until expanded.
    expect(screen.getByText("Archived")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /toggle archived spaces/i }),
    ).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("Gone Space")).toBeNull();
  });

  it("clicking the archived header expands then collapses the list", () => {
    act(() => {
      useStore.setState({
        spaces: [],
        archivedSpaces: [{ id: 9, slug: "gone", name: "Gone Space" }],
        archivedCollapsed: true,
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    const toggle = screen.getByRole("button", {
      name: /toggle archived spaces/i,
    });

    act(() => {
      toggle.click();
    });
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("Gone Space")).toBeInTheDocument();

    act(() => {
      toggle.click();
    });
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByText("Gone Space")).toBeNull();
  });

  it("does not render the Archived section when there are no archived spaces", () => {
    act(() => {
      useStore.setState({
        spaces: [{ id: 1, slug: "active", name: "Active Space" }],
        archivedSpaces: [],
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByText("Archived")).toBeNull();
  });

  it("clicking Restore pushes unarchive_space with the space id", async () => {
    act(() => {
      useStore.setState({
        spaces: [],
        archivedSpaces: [{ id: 3, slug: "gone", name: "Gone Space" }],
        archivedCollapsed: true,
      });
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    // Expand the collapsed Archived section so the Restore button
    // is reachable.
    act(() => {
      screen.getByRole("button", { name: /toggle archived spaces/i }).click();
    });

    const pushPromise = captureNextPush("lobby", "unarchive_space");
    act(() => {
      screen.getByRole("button", { name: /restore gone space/i }).click();
    });

    const payload = await pushPromise;
    expect(payload).toEqual({ space_id: 3 });
  });
});

describe("Sidebar agent unarchiving", () => {
  function seedArchivedAgent(spaceId) {
    act(() => {
      useStore.setState({
        agents: [],
        archivedAgents: [
          {
            name: "old-agent",
            space_id: spaceId,
            parentId: null,
            parentName: null,
            depth: 0,
            archived: true,
          },
        ],
        spaces: [{ id: spaceId, slug: "my-space", name: "My Space" }],
      });
    });
  }

  function expandArchivedGroup() {
    act(() => {
      screen.getByRole("button", { name: /toggle archived agents/i }).click();
    });
  }

  it("renders an archived row as a labelled non-link with a Restore button", () => {
    seedArchivedAgent(1);

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    // The Archived group is collapsed by default; expanding it
    // reveals the row and its Restore button.
    expandArchivedGroup();

    expect(
      screen.getByRole("button", { name: /restore old-agent/i }),
    ).toBeInTheDocument();

    // The agent is stopped, so its chat URL cannot be joined (the
    // backend answers `agent_archived`). The row still names the agent
    // but must not link there.
    expect(screen.getByText("old-agent")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /old-agent/ })).toBeNull();
  });

  it("shows the refusal, naming the parent, when a restore is refused", async () => {
    seedArchivedAgent(1);

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expandArchivedGroup();

    setNextPushResult("lobby", "unarchive_agent", {
      error: { reason: "parent_archived", parent: "root" },
    });

    act(() => {
      screen.getByRole("button", { name: /restore old-agent/i }).click();
    });

    // A silent no-op is the bug this refusal replaces: the message
    // names the parent that has to be restored first.
    expect(await screen.findByRole("alert")).toHaveTextContent(
      /parent "root" is still archived/i,
    );
  });

  it("clicking Restore pushes unarchive_agent with the agent name and space id", async () => {
    seedArchivedAgent(7);

    render(
      <MemoryRouter initialEntries={["/space/my-space"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expandArchivedGroup();

    const pushPromise = captureNextPush("lobby", "unarchive_agent");
    act(() => {
      screen.getByRole("button", { name: /restore old-agent/i }).click();
    });

    const payload = await pushPromise;
    expect(payload).toEqual({ name: "old-agent", space_id: 7 });
  });
});

describe("Sidebar logout", () => {
  beforeEach(() => {
    useStore.getState()._reset();
  });

  function renderSidebar() {
    return render(
      <MemoryRouter initialEntries={["/spaces"]}>
        <Routes>
          <Route path="/spaces" element={<Sidebar />} />
          <Route path="/login" element={<div>LOGIN PAGE</div>} />
        </Routes>
      </MemoryRouter>,
    );
  }

  it("disconnects the socket, resets the store, and navigates to /login on logout", () => {
    const disconnect = vi.fn();
    window.__nest_socket = { disconnect };
    useStore.setState({
      currentUser: { id: 1, username: "admin", is_admin: true },
    });

    renderSidebar();
    act(() => {
      screen.getByRole("button", { name: /logout/i }).click();
    });

    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(useStore.getState().currentUser).toBeNull();
    expect(screen.getByText("LOGIN PAGE")).toBeInTheDocument();

    delete window.__nest_socket;
  });

  it("logs out even when the socket is missing or lacks a disconnect method", () => {
    // A socket object without a `disconnect` method.
    window.__nest_socket = {};
    useStore.setState({ currentUser: { id: 2, username: "bob" } });
    const first = renderSidebar();
    act(() => {
      screen.getByRole("button", { name: /logout/i }).click();
    });
    expect(useStore.getState().currentUser).toBeNull();
    first.unmount();

    // No socket at all.
    delete window.__nest_socket;
    useStore.setState({ currentUser: { id: 3, username: "carol" } });
    renderSidebar();
    act(() => {
      screen.getByRole("button", { name: /logout/i }).click();
    });
    expect(useStore.getState().currentUser).toBeNull();

    delete window.__nest_socket;
  });
});
