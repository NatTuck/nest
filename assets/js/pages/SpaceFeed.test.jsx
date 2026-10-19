/**
 * Tests for the space feed — `/space/:slug`, the space's note log.
 *
 * The feed renders one table (`user_notes`) and nothing else, so these tests are
 * about what the operator sees: the notes and who they are between, the three
 * states that are not "no notes", the owed-reply banner, the recipient the
 * composer defaults to, and the query a send becomes.
 *
 * The store is mocked with a selector-based `useStore`; the transport is mocked
 * so a send can be inspected without a socket.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { fireEvent, render, screen, within } from "@testing-library/react";

let mockState = {};

const mocks = vi.hoisted(() => ({
  requestSpaceFeed: vi.fn(),
  sendSpaceNote: vi.fn(),
  editSpace: vi.fn(),
  cancelEditSpace: vi.fn(),
}));

vi.mock("../channels", () => ({
  requestSpaceFeed: mocks.requestSpaceFeed,
  sendSpaceNote: mocks.sendSpaceNote,
  editSpace: mocks.editSpace,
  cancelEditSpace: mocks.cancelEditSpace,
}));

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

// The hook is covered directly by `useScrollToBottom.test.js` (23 tests over
// fabricated element metrics). Mocking it here is about the *wiring*: that the
// feed hands it the right container, anchor, reset key and trigger, and that
// what it reports reaches the button.
const scroll = vi.hoisted(() => ({ useScrollToBottom: vi.fn() }));

vi.mock("../hooks/useScrollToBottom", () => ({
  useScrollToBottom: scroll.useScrollToBottom,
}));

import { SpaceFeed } from "./SpaceFeed";

const SPACE = {
  id: 1,
  name: "My Space",
  slug: "my-space",
  blueprint_id: 10,
  workspace_path: "/home/nat/ws",
  network_access: true,
  sandbox_backend: "bwrap",
};

const BLUEPRINT = { id: 10, name: "Tabletop RPG" };

const AGENTS = [
  { name: "boss", space_id: 1, status: "idle", depth: 0, parentId: null },
  { name: "minion", space_id: 1, status: "idle", depth: 1, parentId: 1 },
];

function note(overrides) {
  return {
    id: 1,
    space_id: 1,
    from_kind: "agent",
    from_name: "boss",
    to_kind: "user",
    to_name: "alice",
    content: "a note",
    kind: "agent",
    inserted_at: "2026-10-18T12:00:00.000000Z",
    answered_at: null,
    ...overrides,
  };
}

/** The store as the feed reads it: one space, its feed entry, and the user. */
function withFeed(feed, overrides = {}) {
  mockState = {
    spaceFeeds: feed === undefined ? {} : { 1: feed },
    currentUser: { id: 7, username: "alice" },
    lobbyJoined: true,
    pausedSpaces: [],
    ...overrides,
  };
}

function readyFeed(notes, overrides = {}) {
  return {
    notes,
    status: "ready",
    error: null,
    modes: ["plan", "act"],
    defaultMode: "plan",
    ...overrides,
  };
}

// The environment card is collapsed by default; its contents are behind a
// disclosure whose accessible name is the summary row's text.
function expandEnvironment() {
  fireEvent.click(screen.getByRole("button", { name: /Environment/ }));
}

function renderFeed(props = {}) {
  return render(
    <SpaceFeed
      space={SPACE}
      blueprint={BLUEPRINT}
      spaceAgents={AGENTS}
      {...props}
    />,
  );
}

beforeEach(() => {
  mocks.requestSpaceFeed.mockReset();
  mocks.sendSpaceNote.mockReset();
  mocks.editSpace.mockReset();
  mocks.cancelEditSpace.mockReset();
  scroll.useScrollToBottom.mockReset();
  scroll.useScrollToBottom.mockReturnValue({
    isAtBottom: true,
    hasNewContent: false,
    jumpToBottom: vi.fn(),
  });
  withFeed(readyFeed([]));
});

describe("following new notes", () => {
  it("hands the hook the feed's container, anchor, space and notes", () => {
    const jumpToBottom = vi.fn();
    scroll.useScrollToBottom.mockReturnValue({
      isAtBottom: false,
      hasNewContent: true,
      jumpToBottom,
    });

    renderFeed();

    const [container, anchorEl, id, trigger] =
      scroll.useScrollToBottom.mock.calls.at(-1);

    // Real elements, not refs: the notes area mounts after the first render
    // (the feed starts loading), and the hook re-runs its effects when they
    // appear.
    expect(container).toBeInstanceOf(HTMLElement);
    expect(anchorEl).toBeInstanceOf(HTMLElement);
    // `space.id` is the reset key, so navigating to another space starts at its
    // latest note instead of inheriting this one's scroll position.
    expect(id).toBe(SPACE.id);
    // The notes array is the trigger: the store replaces it on every push.
    expect(trigger).toEqual([]);

    // Scrolled up with unseen notes: the jump is offered, and it jumps.
    fireEvent.click(
      screen.getByRole("button", { name: "Jump to latest messages" }),
    );
    expect(jumpToBottom).toHaveBeenCalled();
  });

  it("offers no jump when the reader is already at the bottom", () => {
    // Content arriving while pinned has already been followed, so there is
    // nothing to jump to.
    scroll.useScrollToBottom.mockReturnValue({
      isAtBottom: true,
      hasNewContent: true,
      jumpToBottom: vi.fn(),
    });

    renderFeed();

    expect(
      screen.queryByRole("button", { name: "Jump to latest messages" }),
    ).not.toBeInTheDocument();
  });
});

describe("SpaceFeed", () => {
  it("reads the space's notes once on open", () => {
    renderFeed();

    expect(mocks.requestSpaceFeed).toHaveBeenCalledWith(1);
    expect(mocks.requestSpaceFeed).toHaveBeenCalledTimes(1);
  });

  it("waits for the lobby to be joined before asking, because the read is its push", () => {
    // A push sent between the socket handshake and the lobby's join is refused,
    // and a page that asked then would show a failed read for a connection that
    // is still coming up.
    // No entry at all: nothing has been read, which is what a hard load of the
    // page before the lobby joins looks like.
    withFeed(undefined, { lobbyJoined: false });
    const { unmount } = renderFeed();

    expect(mocks.requestSpaceFeed).not.toHaveBeenCalled();
    // Nothing has been read, so the page says it is loading rather than that
    // the space is empty.
    expect(screen.getByText(/loading this space’s notes/i)).toBeInTheDocument();
    expect(screen.getByLabelText("Message")).toBeDisabled();
    unmount();

    // Once the lobby is up, the read goes out.
    withFeed(readyFeed([]), { lobbyJoined: true });
    renderFeed();

    expect(mocks.requestSpaceFeed).toHaveBeenCalledWith(1);
  });

  it("shows each note with who said it to whom, in the server's order", () => {
    withFeed(
      readyFeed([
        note({
          id: 1,
          from_name: "boss",
          content: "did you see this?",
          kind: "query",
        }),
        note({
          id: 2,
          from_kind: "user",
          from_name: "alice",
          to_kind: "agent",
          to_name: "boss",
          content: "yes",
        }),
        note({
          id: 3,
          from_kind: "runtime",
          from_name: "minion",
          content: "did not reply",
          kind: "runtime",
        }),
      ]),
    );

    renderFeed();

    const items = within(
      screen.getByRole("list", { name: "Notes" }),
    ).getAllByRole("listitem");
    expect(items).toHaveLength(3);

    // The direction line is the header vocabulary: an agent, the human's own
    // words (which are "you" on their own feed), and the runtime about an agent.
    expect(items[0]).toHaveTextContent("from agent boss → you");
    expect(items[0]).toHaveTextContent("did you see this?");
    expect(items[1]).toHaveTextContent("from you → agent boss");
    expect(items[1]).toHaveTextContent("yes");
    expect(items[2]).toHaveTextContent(
      "from nest runtime (about minion) → you",
    );
    expect(items[2]).toHaveTextContent("did not reply");

    // The time is display-only; the row's own `inserted_at` is what it states.
    expect(items[0].querySelector("time")).toHaveAttribute(
      "dateTime",
      "2026-10-18T12:00:00.000000Z",
    );
  });

  it("says a query is still waiting for an answer, and says when it was answered", () => {
    withFeed(
      readyFeed([
        note({ id: 1, kind: "query", content: "which one?" }),
        note({
          id: 2,
          kind: "query",
          content: "and this?",
          answered_at: "2026-10-18T12:01:00.000000Z",
        }),
        note({
          id: 3,
          from_kind: "user",
          from_name: "alice",
          to_kind: "agent",
          to_name: "boss",
          kind: "query",
          content: "status?",
        }),
      ]),
    );

    renderFeed();

    const items = within(
      screen.getByRole("list", { name: "Notes" }),
    ).getAllByRole("listitem");
    expect(items[0]).toHaveTextContent("waiting for your reply");
    expect(items[1]).toHaveTextContent("you answered");
    // A query the human sent waits for the *agent's* answer, not theirs.
    expect(items[2]).toHaveTextContent("waiting for an answer");
  });

  it("says the notes are loading, and says so when the read failed, offering a retry", () => {
    withFeed({
      ...readyFeed([]),
      status: "loading",
      modes: [],
      defaultMode: null,
    });
    const { unmount } = renderFeed();

    expect(screen.getByText(/loading this space’s notes/i)).toBeInTheDocument();
    // Loading is not emptiness: the empty sentence is not on screen.
    expect(
      screen.queryByText(/nothing has been said/i),
    ).not.toBeInTheDocument();
    unmount();
    mocks.requestSpaceFeed.mockClear();

    // A failed read says so, names the reason, and offers the retry — it never
    // renders an empty feed as if there were nothing to say.
    withFeed({
      ...readyFeed([]),
      status: "error",
      error: "Could not load the notes in this space.",
    });
    renderFeed();

    const alert = screen.getByRole("alert");
    expect(alert).toHaveTextContent(
      "The notes in this space could not be loaded.",
    );
    expect(alert).toHaveTextContent("Could not load the notes in this space.");
    expect(
      screen.queryByText(/nothing has been said/i),
    ).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Try again" }));

    expect(mocks.requestSpaceFeed).toHaveBeenCalledTimes(2);
    expect(mocks.requestSpaceFeed).toHaveBeenLastCalledWith(1);
  });

  it("says nothing has been said only once the server has answered with nothing", () => {
    renderFeed();

    expect(
      screen.getByText(/nothing has been said in this space yet/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("list", { name: "Notes" }),
    ).not.toBeInTheDocument();
  });

  it("lists the agents waiting on a reply, and one of them becomes the recipient", () => {
    withFeed(
      readyFeed([
        note({ id: 1, from_name: "minion", kind: "query", content: "q1" }),
        note({ id: 2, from_name: "minion", kind: "query", content: "q2" }),
        note({
          id: 3,
          from_name: "boss",
          kind: "query",
          content: "q3",
          answered_at: "2026-10-18T12:05:00.000000Z",
        }),
        note({
          id: 4,
          from_name: "boss",
          kind: "agent",
          content: "not a query",
        }),
      ]),
    );

    renderFeed();

    // The recipient starts as the root, not as whoever asked.
    expect(screen.getByLabelText("Send to")).toHaveValue("boss");

    // The banner is per agent and counts what is still outstanding: one agent
    // can ask twice, and an answered query is not outstanding.
    expect(
      screen.getByRole("button", { name: "Reply to minion (2 notes)" }),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Reply to boss/ }),
    ).not.toBeInTheDocument();

    fireEvent.click(
      screen.getByRole("button", { name: "Reply to minion (2 notes)" }),
    );

    // The reply's recipient is the agent that asked.
    expect(screen.getByLabelText("Send to")).toHaveValue("minion");
  });

  it("renders no owed-reply banner when nothing is outstanding", () => {
    renderFeed();

    expect(
      screen.queryByText(/waiting for your reply/i),
    ).not.toBeInTheDocument();
  });

  it("sends a query to the root agent by default, carrying the draft mode", () => {
    renderFeed();

    // The root agent is the recipient until the user says otherwise.
    const picker = screen.getByLabelText("Send to");
    expect(picker).toHaveValue("boss");
    expect(
      within(picker).getByRole("option", { name: "minion (depth 1)" }),
    ).toBeInTheDocument();

    // The mode is a draft: the selector states what this message asks for, and
    // the space's default seeds it.
    expect(screen.getByLabelText("Mode")).toHaveValue("plan");

    fireEvent.change(screen.getByLabelText("Message"), {
      target: { value: "  what is the status?  " },
    });
    fireEvent.click(screen.getByRole("button", { name: /send/i }));

    // A query, because a query is what obliges the agent to answer.
    expect(mocks.sendSpaceNote).toHaveBeenCalledTimes(1);
    expect(mocks.sendSpaceNote.mock.calls[0].slice(0, 4)).toEqual([
      1,
      "boss",
      "what is the status?",
      "plan",
    ]);

    // The input is cleared on send, like the agent page's composer.
    expect(screen.getByLabelText("Message")).toHaveValue("");
  });

  it("sends to the agent the picker selects", () => {
    renderFeed();

    fireEvent.change(screen.getByLabelText("Send to"), {
      target: { value: "minion" },
    });
    fireEvent.change(screen.getByLabelText("Message"), {
      target: { value: "hi" },
    });
    fireEvent.click(screen.getByRole("button", { name: /send/i }));

    expect(mocks.sendSpaceNote.mock.calls[0].slice(0, 2)).toEqual([
      1,
      "minion",
    ]);
  });

  it("says the space has no agent to send to rather than offering an empty picker", () => {
    renderFeed({ spaceAgents: [] });

    expect(
      screen.getByText(/no agents yet, so there is nobody to send a note to/i),
    ).toBeInTheDocument();
    expect(screen.queryByLabelText("Send to")).not.toBeInTheDocument();
    // Nothing can be sent: the composer is disabled, not silently ignored.
    expect(screen.getByLabelText("Message")).toBeDisabled();
  });

  it("shows the space's environment, and edits it through the dialog", () => {
    renderFeed();

    // Collapsed, the summary row still states the workspace: that is the fact
    // that makes a space unusable when it is missing, so it is not behind the
    // disclosure. Everything else is.
    expect(screen.getByText("/home/nat/ws")).toBeInTheDocument();
    expect(
      screen.queryByText("Agents in this space can reach the network."),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Edit space" }),
    ).not.toBeInTheDocument();

    expandEnvironment();

    expect(
      screen.getByText("Agents in this space can reach the network."),
    ).toBeInTheDocument();
    expect(screen.getByText("bwrap")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Edit space" }));

    expect(
      screen.getByRole("dialog", { name: "Edit space" }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Workspace Path").value).toBe("/home/nat/ws");
    // Opening it pushes nothing: the dialog's Save is the only writer.
    expect(mocks.editSpace).not.toHaveBeenCalled();

    // Closing it closes it: the card owns the dialog's open state.
    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    expect(
      screen.queryByRole("dialog", { name: "Edit space" }),
    ).not.toBeInTheDocument();
    // Closing tells the server, not just this component: a save may have taken
    // the space's latch, and only a release gives it back.
    expect(mocks.cancelEditSpace).toHaveBeenCalledWith(1);
  });

  it("says so when a space has no workspace recorded", () => {
    renderFeed({ space: { ...SPACE, workspace_path: null } });

    expect(
      screen.getByText("no workspace recorded for this space"),
    ).toBeInTheDocument();
  });

  it("says a space with no sandbox cannot enforce network access", () => {
    renderFeed({ space: { ...SPACE, sandbox_backend: "none" } });

    expandEnvironment();

    expect(screen.getByText(/nothing enforces that/i)).toBeInTheDocument();
  });

  it("says the space is paused, once, because a held space is held for every page", () => {
    withFeed(readyFeed([]), { pausedSpaces: [1] });

    renderFeed();

    expect(screen.getByRole("status")).toHaveTextContent("My Space is paused");
  });

  it("marks an unknown mode rather than claiming one", () => {
    // The server is the authority on the mode catalog; a feed entry without a
    // default mode leaves the selector saying it does not know, instead of
    // picking one the server never agreed to.
    withFeed({ ...readyFeed([]), defaultMode: null });

    renderFeed();

    expect(screen.getByRole("alert")).toHaveTextContent("mode: (missing)");
  });
});
