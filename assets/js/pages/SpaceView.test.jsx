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
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

let mockState = { spaces: [], agents: [], blueprints: [] };

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

import { SpaceView } from "./SpaceView";

function renderView(spaceSlug = "my-space") {
  return render(
    <MemoryRouter initialEntries={[`/space/${spaceSlug}`]}>
      <Routes>
        <Route path="/space/:spaceSlug" element={<SpaceView />} />
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
      { id: 1, name: "My Space", slug: "my-space", blueprint_id: 10 },
      { id: 2, name: "Other Space", slug: "other-space", blueprint_id: null },
    ],
    agents: [
      {
        name: "dm",
        space_id: 1,
        status: "idle",
        depth: 0,
        parent_id: null,
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
        { name: "dm", space_id: 1, status: "executing_tools", depth: 0 },
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
