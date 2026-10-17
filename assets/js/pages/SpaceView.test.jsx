/**
 * Tests for the SpaceView Main View page.
 *
 * Covers rendering the space + blueprint header, filtering agents by
 * `space_id`, agent links + depth badge + status, the empty and
 * not-found states, and the page title (host + space name, falling back
 * to the route slug when the store has no matching space).
 *
 * The store is mocked with a selector-based `useStore`; `spaceSlug`
 * comes from the route params via a real MemoryRouter.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useParams } from "react-router-dom";

let mockState = { spaces: [], agents: [], blueprints: [] };

const mocks = vi.hoisted(() => ({ setSpaceNetwork: vi.fn() }));

vi.mock("../channels", () => ({
  setSpaceNetwork: mocks.setSpaceNetwork,
}));

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

import { SpaceView } from "./SpaceView";

// The redirect target, so the test can see *which* agent it landed on.
function AgentChatStub() {
  const { name } = useParams();
  return <p>agent chat: {name}</p>;
}

function renderView(spaceSlug = "my-space") {
  return render(
    <MemoryRouter initialEntries={[`/space/${spaceSlug}`]}>
      <Routes>
        <Route path="/space/:spaceSlug" element={<SpaceView />} />
        <Route
          path="/space/:spaceSlug/agent/:name"
          element={<AgentChatStub />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  // The host the server injects into `window.NEST_CONFIG`, plus the
  // shell's default title: a page test proves the page *replaces* it.
  window.NEST_CONFIG = { host: "vampire" };
  document.title = "Nest · Phoenix Framework";

  mockState = {
    spaces: [
      {
        id: 1,
        name: "My Space",
        slug: "my-space",
        blueprint_id: 10,
        network_access: true,
        sandbox_backend: "bwrap",
      },
      { id: 2, name: "Other Space", slug: "other-space", blueprint_id: null },
    ],
    // No root agent in the default fixture. `/space/:slug` now redirects to the
    // root agent's chat (#96), so the overview below is what renders in the one
    // state where there is nothing to redirect to: a space whose root agent has
    // not appeared yet. `dm` is a child of that not-yet-listed root.
    agents: [
      {
        name: "dm",
        space_id: 1,
        status: "idle",
        depth: 0,
        parent_id: 1,
      },
      {
        name: "npc",
        space_id: 1,
        status: "streaming",
        depth: 1,
        parent_id: 1,
      },
      { name: "other-agent", space_id: 2, status: "idle", depth: 0 },
    ],
    blueprints: [{ id: 10, name: "Tabletop RPG" }],
  };
});

describe("SpaceView", () => {
  it("renders the space name and blueprint name", () => {
    renderView();

    expect(
      screen.getByRole("heading", { name: "My Space" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Blueprint: Tabletop RPG")).toBeInTheDocument();
    expect(document.title).toBe("vampire · My Space");
  });

  it("only lists agents in the current space", () => {
    renderView();

    expect(screen.getByText("dm")).toBeInTheDocument();
    expect(screen.getByText("npc")).toBeInTheDocument();
    expect(screen.queryByText("other-agent")).not.toBeInTheDocument();
  });

  it("links each agent to its chat page", () => {
    renderView();

    const dmLink = screen.getByRole("link", { name: /dm/ });
    expect(dmLink).toHaveAttribute("href", "/space/my-space/agent/dm");
  });

  it("shows a depth badge and status for sub-agents", () => {
    renderView();

    expect(screen.getByText("(depth 1)")).toBeInTheDocument();
    expect(screen.getByText("streaming")).toBeInTheDocument();
  });

  it("renders agents in an executing-tools status", () => {
    mockState = {
      ...mockState,
      agents: [
        {
          name: "dm",
          space_id: 1,
          status: "executing_tools",
          depth: 0,
          parent_id: 1,
        },
      ],
    };

    renderView();

    expect(screen.getByText("executing_tools")).toBeInTheDocument();
  });

  it("renders an empty state when the space has no agents", () => {
    mockState = {
      ...mockState,
      agents: [],
    };

    renderView();

    expect(
      screen.getByText("No agents in this space yet."),
    ).toBeInTheDocument();
  });

  it("shows the space's network access and pushes a change to the channel", () => {
    renderView();

    const toggle = screen.getByLabelText("Network access");
    expect(toggle.checked).toBe(true);

    fireEvent.click(toggle);

    expect(mocks.setSpaceNetwork).toHaveBeenCalledWith(
      1,
      false,
      expect.any(Function),
      expect.any(Function),
    );
  });

  it("says a space with no sandbox cannot enforce network access", () => {
    mockState.spaces[0].sandbox_backend = "none";

    renderView();

    expect(screen.getByText(/nothing enforces that/i)).toBeInTheDocument();
  });

  it("warns that a docker space's container restarts when the network changes", () => {
    // `--network none` is fixed when a container is created, so the change
    // releases it — and with it the agents' `/tmp` (offloads, job logs) and any
    // running background job. The user is told before flipping the toggle, not
    // after.
    mockState.spaces[0].sandbox_backend = "docker";

    renderView();

    const warning = screen.getByText(/restarts this space's container/i);
    expect(warning).toBeInTheDocument();
    expect(warning.textContent).toMatch(/background-job logs/i);
  });

  it("redirects to the root agent's chat, replacing the entry", () => {
    // The default Main View (#96): clicking a space is clicking its root
    // agent's chat, not an overview you then have to click through.
    mockState = {
      ...mockState,
      agents: [
        {
          name: "boss",
          space_id: 1,
          status: "idle",
          depth: 0,
          parent_id: null,
        },
        {
          name: "minion",
          space_id: 1,
          status: "idle",
          depth: 1,
          parent_id: 1,
        },
      ],
    };

    renderView();

    // The root, not the sub-agent.
    expect(screen.getByText("agent chat: boss")).toBeInTheDocument();
  });

  it("renders the blueprint's own Main View when it names one", () => {
    // `main_view_config` is the blueprint's hook for the main screen. A
    // campaign space gets its own page instead of the game master's transcript.
    mockState = {
      ...mockState,
      agents: [
        { name: "gm", space_id: 1, status: "idle", depth: 0, parent_id: null },
      ],
      blueprints: [
        { id: 10, name: "Tabletop RPG", main_view_config: { view: "rpg" } },
      ],
    };

    renderView();

    expect(
      screen.getByRole("heading", { name: "RPG Play Interface" }),
    ).toBeInTheDocument();
    // ...and it did not redirect to the game master's chat.
    expect(screen.queryByText(/^agent chat:/)).not.toBeInTheDocument();
  });

  it("renders the not-found state for an unknown slug", () => {
    renderView("nope");

    expect(
      screen.getByRole("heading", { name: "Space not found" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: "Back to spaces" }),
    ).toHaveAttribute("href", "/spaces");
    // The store has no space for this slug (a hard load of a deep URL),
    // so the title falls back to the slug itself rather than going
    // blank or showing a placeholder.
    expect(document.title).toBe("vampire · nope");
  });
});
