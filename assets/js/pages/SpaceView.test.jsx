/**
 * Tests for the SpaceView Main View page and the space's overview.
 *
 * Covers rendering the space + blueprint header and its environment,
 * filtering agents by `space_id`, agent links + depth badge + status, the
 * empty and not-found states, the page title (host + space name, falling back
 * to the route slug when the store has no matching space), and that the
 * environment dialog is opened from here — the environment is the space's, so
 * the space's page is where it is edited.
 *
 * The two spellings of the space's pages are both exercised, because the
 * difference between them is the point: `/space/:slug` is the blueprint's Main
 * View (a redirect to the root agent's chat by default), and
 * `/space/:slug/overview` is the space's own page. A real space always has a
 * root agent, so the overview is only reachable through the second.
 *
 * The store is mocked with a selector-based `useStore`; `spaceSlug`
 * comes from the route params via a real MemoryRouter.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import {
  MemoryRouter,
  Routes,
  Route,
  useNavigate,
  useParams,
} from "react-router-dom";

// `pausedSpaces` is the space edit's latch (`SpacePausedBanner` reads it); no
// space is paused in these tests.
let mockState = { spaces: [], agents: [], blueprints: [], pausedSpaces: [] };

const mocks = vi.hoisted(() => ({ editSpace: vi.fn() }));

// `EditSpaceDialog` pushes the edit; the page only opens it.
vi.mock("../channels", () => ({
  editSpace: mocks.editSpace,
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

// The browser's back button, as far as the router can see it: it renders on
// every harness below so any test can step back through the history.
function BackButton() {
  const navigate = useNavigate();
  return (
    <button type="button" onClick={() => navigate(-1)}>
      back
    </button>
  );
}

// Both of the space's spellings, plus where the redirect lands and where Back
// can go. Rendered once so a test that starts on either spelling is testing the
// real routing rather than a component in isolation.
function renderAt(entries) {
  return render(
    <MemoryRouter initialEntries={entries}>
      <BackButton />
      <Routes>
        <Route path="/spaces" element={<p>spaces index</p>} />
        <Route path="/space/:spaceSlug" element={<SpaceView />} />
        <Route
          path="/space/:spaceSlug/overview"
          element={<SpaceView overview />}
        />
        <Route
          path="/space/:spaceSlug/agent/:name"
          element={<AgentChatStub />}
        />
      </Routes>
    </MemoryRouter>,
  );
}

function renderView(spaceSlug = "my-space", entry = `/space/${spaceSlug}`) {
  return renderAt([entry]);
}

// A space with a root agent, which is every real space:
// `create_space_with_root_agent/2` is the only creation path. The redirect on
// `/space/:slug` is what the overview path has to survive.
function withRootAgent() {
  mockState = {
    ...mockState,
    agents: [
      { name: "boss", space_id: 1, status: "idle", depth: 0, parent_id: null },
      {
        name: "minion",
        space_id: 1,
        status: "idle",
        depth: 1,
        parent_id: 1,
      },
    ],
  };
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
        workspace_path: "/home/nat/ws",
        network_access: true,
        sandbox_backend: "bwrap",
      },
      { id: 2, name: "Other Space", slug: "other-space", blueprint_id: null },
    ],
    // No root agent in the default fixture. `/space/:slug` redirects to the
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
    pausedSpaces: [],
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

  it("shows the space's environment", () => {
    renderView();

    expect(screen.getByText("/home/nat/ws")).toBeInTheDocument();
    expect(
      screen.getByText("Agents in this space can reach the network."),
    ).toBeInTheDocument();
    expect(screen.getByText("bwrap")).toBeInTheDocument();
  });

  it("says so when a space has no workspace recorded", () => {
    // Not silence: a space without a workspace is a row no agent in it can
    // start in, so the page has to say that rather than render an empty line.
    mockState.spaces[0].workspace_path = null;

    renderView();

    expect(
      screen.getByText("no workspace recorded for this space"),
    ).toBeInTheDocument();
  });

  it("opens the environment dialog from the space's page", () => {
    renderView();

    fireEvent.click(screen.getByRole("button", { name: "Edit space" }));

    const dialog = screen.getByRole("dialog", { name: "Edit space" });
    expect(dialog).toBeInTheDocument();
    // Pre-filled from the space, not blank.
    expect(screen.getByLabelText("Workspace Path").value).toBe("/home/nat/ws");
    expect(screen.getByLabelText("Sandbox").value).toBe("bwrap");
    // Opening it pushes nothing: the dialog's Save is the only writer.
    expect(mocks.editSpace).not.toHaveBeenCalled();
  });

  it("says a space with no sandbox cannot enforce network access", () => {
    mockState.spaces[0].sandbox_backend = "none";

    renderView();

    expect(screen.getByText(/nothing enforces that/i)).toBeInTheDocument();
  });

  it("redirects to the root agent's chat, replacing the entry", () => {
    // The default Main View (#96): clicking a space is clicking its root
    // agent's chat, not an overview you then have to click through.
    withRootAgent();

    renderView();

    // The root, not the sub-agent.
    expect(screen.getByText("agent chat: boss")).toBeInTheDocument();
  });

  it("renders the overview at its own path even though the space has a root agent", () => {
    // The reason the overview has a path at all: `/space/:slug` redirects, and
    // a real space always has a root agent, so before this route the overview —
    // and with it the environment dialog — was unreachable for every space that
    // exists.
    withRootAgent();

    renderView("my-space", "/space/my-space/overview");

    expect(
      screen.getByRole("heading", { name: "My Space" }),
    ).toBeInTheDocument();
    expect(screen.queryByText(/^agent chat:/)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Edit space" }));

    expect(
      screen.getByRole("dialog", { name: "Edit space" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Workspace Path").value).toBe("/home/nat/ws");
  });

  it("leaves the space's own entry off the history, so Back does not bounce", () => {
    // The redirect uses `replace`: the space's URL never sits on the stack, so
    // Back goes where the user came from. Pushed instead, Back would land on
    // `/space/my-space`, which redirects again — the button would never leave
    // the space.
    withRootAgent();

    renderAt(["/spaces", "/space/my-space"]);

    expect(screen.getByText("agent chat: boss")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "back" }));

    expect(screen.getByText("spaces index")).toBeInTheDocument();
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

  it("gives a campaign space's overview its own path too", () => {
    // The `rpg` Main View wins on `/space/:slug`, but the overview is the
    // space's own page and ignores the Main View: without this route a campaign
    // space would have no page for its environment at all.
    mockState = {
      ...mockState,
      agents: [
        { name: "gm", space_id: 1, status: "idle", depth: 0, parent_id: null },
      ],
      blueprints: [
        { id: 10, name: "Tabletop RPG", main_view_config: { view: "rpg" } },
      ],
    };

    renderView("my-space", "/space/my-space/overview");

    expect(
      screen.getByRole("heading", { name: "My Space" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "RPG Play Interface" }),
    ).not.toBeInTheDocument();
    // The agent list is the way back to the campaign's chat.
    expect(screen.getByRole("link", { name: /gm/ })).toHaveAttribute(
      "href",
      "/space/my-space/agent/gm",
    );
  });

  it("says on the overview that the space is paused, once", () => {
    // The space edit holds work while it lands, and the overview is where the
    // edit is started — so it has to say so. One banner: `getByRole` throws on
    // two, so this also proves the page does not double-render it. (That it
    // renders nothing when the space is *not* paused is the banner's own test.)
    withRootAgent();
    mockState = { ...mockState, pausedSpaces: [1] };

    renderView("my-space", "/space/my-space/overview");

    expect(screen.getByRole("status")).toHaveTextContent("My Space is paused");
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
