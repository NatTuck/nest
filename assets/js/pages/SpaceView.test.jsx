/**
 * Tests for SpaceView — `/space/:slug`, the space's own page.
 *
 * What this file is about is the **dispatch**: the route is the space's note
 * feed, a blueprint that names an `rpg` Main View still wins, and the two states
 * that are not the page at all (an archived space, an unknown slug). What the
 * feed itself shows is `SpaceFeed.test.jsx`'s.
 *
 * The redirect that used to live here (#96, `/space/:slug` → the root agent's
 * chat) is gone, and so is `/space/:slug/overview`; both are asserted as absences
 * rather than left to a reader to notice.
 *
 * The store is mocked with a selector-based `useStore`; `spaceSlug` comes from
 * the route params via a real MemoryRouter.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useParams } from "react-router-dom";

let mockState = {};

const mocks = vi.hoisted(() => ({
  requestSpaceFeed: vi.fn(),
  sendSpaceNote: vi.fn(),
  editSpace: vi.fn(),
  cancelEditSpace: vi.fn(),
  unarchiveSpace: vi.fn(),
}));

vi.mock("../channels", () => ({
  requestSpaceFeed: mocks.requestSpaceFeed,
  sendSpaceNote: mocks.sendSpaceNote,
  editSpace: mocks.editSpace,
  cancelEditSpace: mocks.cancelEditSpace,
  unarchiveSpace: mocks.unarchiveSpace,
}));

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

import { SpaceView } from "./SpaceView";

// The agent page, so a test can see that the space's own route did *not* land
// on an agent's conversation.
function AgentChatStub() {
  const { name } = useParams();
  return <p>agent chat: {name}</p>;
}

function renderView(spaceSlug = "my-space") {
  return render(
    <MemoryRouter initialEntries={[`/space/${spaceSlug}`]}>
      <Routes>
        <Route path="/spaces" element={<p>spaces index</p>} />
        <Route path="/space/:spaceSlug" element={<SpaceView />} />
        <Route
          path="/space/:spaceSlug/agent/:name"
          element={<AgentChatStub />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

const SPACE = {
  id: 1,
  name: "My Space",
  slug: "my-space",
  blueprint_id: 10,
  workspace_path: "/home/nat/ws",
  network_access: true,
  sandbox_backend: "bwrap",
};

const FEED = {
  notes: [],
  status: "ready",
  error: null,
  modes: ["plan", "act"],
  defaultMode: "act",
};

beforeEach(() => {
  // The host the server injects into `window.NEST_CONFIG`, plus the
  // shell's default title: a page test proves the page *replaces* it.
  window.NEST_CONFIG = { host: "vampire" };
  document.title = "Nest · Phoenix Framework";

  mockState = {
    spaces: [
      SPACE,
      { id: 2, name: "Other Space", slug: "other-space", blueprint_id: null },
    ],
    // The space's root agent, which every real space has: it is what the feed's
    // composer picks by default, and it is what `/space/:slug` used to redirect
    // to.
    agents: [
      { name: "boss", space_id: 1, status: "idle", depth: 0, parentId: null },
      { name: "minion", space_id: 1, status: "idle", depth: 1, parentId: 1 },
      {
        name: "other-agent",
        space_id: 2,
        status: "idle",
        depth: 0,
        parentId: null,
      },
    ],
    blueprints: [{ id: 10, name: "Tabletop RPG", default_mode: "act" }],
    archivedSpaces: [],
    pausedSpaces: [],
    currentUser: { id: 7, username: "alice" },
    lobbyJoined: true,
    spaceFeeds: { 1: FEED },
  };

  for (const mock of Object.values(mocks)) mock.mockReset();
});

describe("SpaceView", () => {
  it("renders the space's note feed at its own path, with no redirect to an agent", () => {
    renderView();

    expect(
      screen.getByRole("heading", { name: "My Space" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Blueprint: Tabletop RPG")).toBeInTheDocument();
    // The feed: a composer with a recipient, and the space's environment.
    // The environment card is collapsed by default, so what its presence looks
    // like here is its disclosure — the workspace path and the edit button are
    // behind it (`SpaceFeed.test.jsx` opens it).
    expect(screen.getByLabelText("Send to")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Environment/ }),
    ).toBeInTheDocument();
    // ...and not the root agent's conversation, which is where this route used
    // to send the user.
    expect(screen.queryByText(/^agent chat:/)).not.toBeInTheDocument();
    expect(document.title).toBe("vampire · My Space");
  });

  it("offers only this space's agents as recipients", () => {
    renderView();

    const picker = screen.getByLabelText("Send to");
    expect(picker).toHaveValue("boss");
    expect(
      screen.getByRole("option", { name: "minion (depth 1)" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("option", { name: /other-agent/ }),
    ).not.toBeInTheDocument();
  });

  it("renders the blueprint's own Main View when it names one, and its environment below", () => {
    // `main_view_config` is the blueprint's hook for the main screen. A campaign
    // space gets its own page instead of a note log — and, because the overview
    // route that used to carry the environment is retired, the environment card
    // is on that page.
    mockState = {
      ...mockState,
      blueprints: [
        { id: 10, name: "Tabletop RPG", main_view_config: { view: "rpg" } },
      ],
    };

    renderView();

    expect(
      screen.getByRole("heading", { name: "RPG Play Interface" }),
    ).toBeInTheDocument();
    expect(screen.queryByLabelText("Send to")).not.toBeInTheDocument();
    // Collapsed by default, so its presence is its disclosure — and the
    // workspace, the one fact that makes a space unusable when missing, is
    // still stated without expanding.
    expect(
      screen.getByRole("button", { name: /Environment/ }),
    ).toBeInTheDocument();
    expect(screen.getByText("/home/nat/ws")).toBeInTheDocument();
  });

  it("shows the pause banner on a campaign's Main View", () => {
    // The `rpg` page is a Main View, not the feed, and a paused space has to be
    // visible there too: this is the one screen with no agent header and no feed
    // in the way, so a pause would read as a stuck page.
    mockState = {
      ...mockState,
      blueprints: [
        { id: 10, name: "Tabletop RPG", main_view_config: { view: "rpg" } },
      ],
      pausedSpaces: [1],
    };

    renderView();

    expect(
      screen.getByRole("heading", { name: "RPG Play Interface" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("My Space is paused");
  });

  it("says an archived space is archived rather than missing, and restores it", () => {
    // The sidebar's archived row links here, and the space exists — it is
    // stopped — so "Space not found" would be a lie about a space the user can
    // see in their sidebar.
    mockState = {
      ...mockState,
      spaces: [],
      archivedSpaces: [
        { id: 9, name: "Old Space", slug: "old-space", blueprint_id: null },
      ],
    };

    renderView("old-space");

    expect(
      screen.getByRole("heading", { name: "Old Space" }),
    ).toBeInTheDocument();
    expect(screen.getByText(/is archived/i)).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "Space not found" }),
    ).not.toBeInTheDocument();
    expect(document.title).toBe("vampire · Old Space");

    fireEvent.click(screen.getByRole("button", { name: "Unarchive space" }));

    // The same push the archived row's own button makes.
    expect(mocks.unarchiveSpace).toHaveBeenCalledWith(9);
    // An archived space is not a feed: there is nothing to read in a space whose
    // agents are stopped.
    expect(mocks.requestSpaceFeed).not.toHaveBeenCalled();
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
