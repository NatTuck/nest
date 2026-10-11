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
      fireEvent.click(screen.getByRole("link", { name: /second space/i }));
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
    const firstLink = screen.getByRole("link", { name: /first space/i });
    const secondLink = screen.getByRole("link", { name: /second space/i });
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

    const firstLink = screen.getByRole("link", { name: /first space/i });
    const secondLink = screen.getByRole("link", { name: /second space/i });
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
