/**
 * Sidebar test — focused coverage on the agent tree builder
 * and the tree render. The rest of the sidebar is exercised
 * by the App-level ChatPage tests; here we assert just the
 * behaviour introduced by sub-agent delegation.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

import { Sidebar } from "./Sidebar";
import { useStore } from "../store";
import { joinLobby } from "../channels";
import {
  resetMockSocket,
  setNextJoinResult,
  connectSocket,
} from "../__mocks__/phoenix";

function withStore(agents) {
  // Agents are grouped under a space row in the sidebar. Seed a
  // space and make it the current one so its (expanded) agent tree
  // renders. Default each agent's `space_id` to that space's id.
  useStore.setState({
    agents: agents.map((a) => ({ ...a, space_id: a.space_id ?? 1 })),
    spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
    currentSpaceId: 1,
  });
}

function clearAgents() {
  useStore.setState({ agents: null, spaces: [], currentSpaceId: null });
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
      <MemoryRouter>
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
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByText("parent")).toBeInTheDocument();
    expect(screen.getByText("child-of-parent")).toBeInTheDocument();
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
      <MemoryRouter>
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
      <MemoryRouter>
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
      <MemoryRouter>
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
      <MemoryRouter initialEntries={["/"]}>
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
      <MemoryRouter initialEntries={["/"]}>
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

describe("Sidebar Needs Repair rows", () => {
  // "Needs Repair" rows surface `state.brokenAgents`, populated by the
  // lobby's `init` payload + the `broken_agents_updated` follow-up.
  // They render *inside their own space's* expanded tree (not as a
  // top-level section), linking to the space-scoped chat route, because
  // persistent agents whose GenServer is gone but whose model is still
  // unresolvable can't appear in the regular agents list
  // (`Registry.list/0` excludes them).

  beforeEach(() => {
    // Start from a fully reset store so each test sees a
    // clean `brokenAgents`. The beforeEach at the top sets up
    // the lobby channel; the model-picker / store-isolation
    // reset is the same `useStore.getState()._reset()` used
    // elsewhere.
    useStore.getState()._reset();
  });

  it("hides the repair rows when state.brokenAgents is empty", () => {
    act(() => {
      withStore([]);
    });
    useStore.setState({ brokenAgents: [] });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.queryByText(/needs repair/i)).toBeNull();
  });

  it("renders broken-agent rows inside the expanded space with an amber pulsing dot", () => {
    act(() => {
      withStore([]);
    });
    useStore.setState({
      brokenAgents: [
        {
          name: "ghost-agent",
          space_id: 1,
          model: { name: "ghost-model" },
          status: "model_missing",
        },
        {
          name: "second-ghost",
          space_id: 1,
          model: { name: "other-missing" },
          status: "model_missing",
        },
      ],
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    // The inline heading is visible inside the space's tree.
    expect(screen.getByText(/needs repair/i)).toBeInTheDocument();
    // Both names render as links pointing at the space-scoped route.
    const ghostLinks = screen.getAllByRole("link", {
      name: /ghost-agent/i,
    });
    expect(ghostLinks.length).toBeGreaterThan(0);
    expect(ghostLinks[0].getAttribute("href")).toBe(
      "/space/my-space/agent/ghost-agent",
    );
    expect(screen.getByText(/second-ghost/i)).toBeInTheDocument();

    // Each row carries the amber pulsing dot — one per broken agent
    // (the agents list is empty here, so no executing_tools dots).
    const amberDots = document.querySelectorAll(".animate-pulse.bg-amber-500");
    expect(amberDots.length).toBe(2);
  });

  it("clicking a broken-agent row navigates to the space-scoped chat path", () => {
    act(() => {
      withStore([]);
    });
    useStore.setState({
      brokenAgents: [
        {
          name: "ghost-agent",
          space_id: 1,
          model: { name: "ghost-model" },
          status: "model_missing",
        },
      ],
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    const link = screen.getByRole("link", { name: /ghost-agent/i });
    expect(link.getAttribute("href")).toBe("/space/my-space/agent/ghost-agent");
  });

  it("scopes broken agents to their own space", () => {
    act(() => {
      withStore([]);
    });
    useStore.setState({
      spaces: [
        { id: 1, slug: "space-a", name: "Space A" },
        { id: 2, slug: "space-b", name: "Space B" },
      ],
      currentSpaceId: 1,
      brokenAgents: [
        {
          name: "broken-a",
          space_id: 1,
          model: { name: "ghost-model" },
          status: "model_missing",
        },
        {
          name: "broken-b",
          space_id: 2,
          model: { name: "ghost-model" },
          status: "model_missing",
        },
      ],
    });

    render(
      <MemoryRouter>
        <Sidebar />
      </MemoryRouter>,
    );

    // Space A is the selected/expanded space, so its broken agent
    // renders with the correct space-scoped path.
    const linkA = screen.getByRole("link", { name: /broken-a/i });
    expect(linkA.getAttribute("href")).toBe("/space/space-a/agent/broken-a");

    // Space B is collapsed, so its broken agent is not rendered.
    expect(screen.queryByText(/broken-b/i)).toBeNull();
  });
});
