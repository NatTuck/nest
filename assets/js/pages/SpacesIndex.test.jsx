/**
 * Tests for the SpacesIndex landing page.
 *
 * Covers the heading + "New Space" action, the empty state, space card
 * rendering with links, and the per-space agent count (singular/plural).
 *
 * The store is mocked with a selector-based `useStore`.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

let mockState = { spaces: [], agents: [] };

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

import { SpacesIndex } from "./SpacesIndex";

function renderIndex() {
  return render(
    <MemoryRouter>
      <SpacesIndex />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  mockState = {
    spaces: [
      { id: 1, name: "My Space", slug: "my-space", blueprint_id: null },
      { id: 2, name: "Other Space", slug: "other-space", blueprint_id: null },
    ],
    agents: [
      { name: "dm", space_id: 1 },
      { name: "npc", space_id: 1 },
      { name: "solo", space_id: 2 },
    ],
  };
});

describe("SpacesIndex", () => {
  it("renders the heading and a New Space link", () => {
    renderIndex();

    expect(screen.getByRole("heading", { name: "Spaces" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "New Space" })).toHaveAttribute(
      "href",
      "/spaces/new",
    );
  });

  it("links each space to its main view", () => {
    renderIndex();

    expect(screen.getByRole("link", { name: /My Space/ })).toHaveAttribute(
      "href",
      "/space/my-space",
    );
    expect(screen.getByRole("link", { name: /Other Space/ })).toHaveAttribute(
      "href",
      "/space/other-space",
    );
  });

  it("shows a plural agent count for a multi-agent space", () => {
    renderIndex();

    expect(screen.getByText("2 agents")).toBeInTheDocument();
  });

  it("shows a singular agent count for a single-agent space", () => {
    renderIndex();

    expect(screen.getByText("1 agent")).toBeInTheDocument();
  });

  it("renders an empty state with a create link when there are no spaces", () => {
    mockState = { spaces: [], agents: [] };

    renderIndex();

    expect(screen.getByText(/No spaces yet\./)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Create one" })).toHaveAttribute(
      "href",
      "/spaces/new",
    );
  });
});
