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
import { useEffect, useReducer } from "react";
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

// The drafts are the one store slice a test drives by typing, and the composer
// is controlled through them — so this stub has to re-render, or every
// keystroke would vanish and a send would look like it was ignored.
let mockDrafts = {};
const draftListeners = new Set();
function setDraft(key, text) {
  mockDrafts = { ...mockDrafts, [key]: text };
  for (const notify of draftListeners) notify();
}
function useDrafts() {
  const [, bump] = useReducer((n) => n + 1, 0);
  useEffect(() => {
    draftListeners.add(bump);
    return () => draftListeners.delete(bump);
  }, []);
  return mockDrafts;
}
vi.mock("../store", () => ({
  useStore: (selector) => {
    const drafts = useDrafts();
    return selector({ ...mockState, drafts, setDraft });
  },
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
  // Off, the column's default (issue #176).
  context_warnings: false,
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

describe("the feed composer's draft", () => {
  // Keyed by space, like the chat composer is keyed by agent: the note box must
  // survive leaving the page, and must not follow the reader to another space.
  beforeEach(() => {
    withFeed(readyFeed([]));
  });

  it("restores the draft when the reader comes back to the space", () => {
    const first = renderFeed();
    fireEvent.change(screen.getByLabelText("Message"), {
      target: { value: "a note I was writing" },
    });
    expect(screen.getByLabelText("Message").value).toBe("a note I was writing");

    first.unmount();

    renderFeed();
    expect(screen.getByLabelText("Message").value).toBe("a note I was writing");
  });

  it("does not carry the draft to another space, without remounting", () => {
    const { rerender } = renderFeed();
    fireEvent.change(screen.getByLabelText("Message"), {
      target: { value: "for space one only" },
    });

    // A *rerender* with another space, not a fresh mount: the feed is the same
    // component before and after, which is the shape a draft held in its own
    // state would have followed.
    rerender(
      <SpaceFeed
        space={{ ...SPACE, id: 2, name: "Other", slug: "other" }}
        blueprint={BLUEPRINT}
        spaceAgents={AGENTS}
      />,
    );

    expect(screen.getByLabelText("Message").value).toBe("");
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
    const disclosure = screen.getByRole("button", { name: /Environment/ });
    expect(disclosure).toHaveAttribute("aria-expanded", "false");
    // `aria-controls` names the body only while the body exists: an IDREF that
    // resolves to nothing is an ARIA violation.
    expect(disclosure).not.toHaveAttribute("aria-controls");

    expect(screen.getByText("/home/nat/ws")).toBeInTheDocument();
    expect(
      screen.queryByText("Agents in this space can reach the network."),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Edit space" }),
    ).not.toBeInTheDocument();

    expandEnvironment();

    expect(disclosure).toHaveAttribute("aria-expanded", "true");
    expect(disclosure).toHaveAttribute(
      "aria-controls",
      "space-environment-body",
    );
    expect(document.getElementById("space-environment-body")).not.toBeNull();

    expect(
      screen.getByText("Agents in this space can reach the network."),
    ).toBeInTheDocument();
    expect(screen.getByText("bwrap")).toBeInTheDocument();
    // The context-warnings setting is the space's too, and it is stated rather
    // than left out when it is off — off is a value, not missing data.
    expect(
      screen.getByText(
        "These agents are not told when their context fills up.",
      ),
    ).toBeInTheDocument();

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

    // Collapsed, the summary row already carries it: a space with no sandbox is
    // a space where the network setting is not enforced, which is a safety
    // consequence rather than a detail, so it does not wait behind the click
    // the way the rest of the card does.
    expect(screen.getByText(/network not enforced/i)).toBeInTheDocument();

    expandEnvironment();

    expect(screen.getByText(/nothing enforces that/i)).toBeInTheDocument();
  });

  it("states that the context warnings are on when the space opted in", () => {
    // The setting is the space's, and a reader has to be able to tell the two
    // states apart from the card rather than from a notice's absence.
    renderFeed({ space: { ...SPACE, context_warnings: true } });
    expandEnvironment();

    expect(
      screen.getByText(
        "These agents are told when their context is 25%, 50% or 75% full.",
      ),
    ).toBeInTheDocument();
    expect(
      screen.queryByText(
        "These agents are not told when their context fills up.",
      ),
    ).not.toBeInTheDocument();
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

describe("SpaceFeed scroll containers (issue #86)", () => {
  // `main` in `Layout` is `overflow-auto`, and on this page that made it a
  // second scroll container: tall chrome (the environment card alone can be
  // taller than a phone viewport) pushed the column past it, and scrolling
  // anywhere over the page then took the space's name and the composer with it —
  // the same defect the chat page had.
  //
  // jsdom has no layout engine, so the overflow itself cannot be measured here;
  // what is pinned is the class contract the fix rests on, because dropping any
  // one clause puts `main` back in the scrolling business: the column clips, the
  // chrome region may shrink and scroll on its own, the notes pane is the one
  // `flex-1` scroll region, and the composer is outside both.
  const panes = (column) =>
    [...column.children].filter((el) =>
      String(el.className).includes("flex-1"),
    );

  it("clips the column, scrolls only the chrome when it must, and never squeezes the composer", () => {
    const { container } = renderFeed();

    const column = container.firstElementChild;
    expect(column.className).toContain("overflow-hidden");

    // The chrome region: the pause banner, the space's name and blueprint, the
    // environment card and the owed-reply banner. Identified positively as well
    // as positionally, so an element added above the header fails loudly here
    // instead of quietly turning this into an assertion about the wrong node.
    const chrome = column.firstElementChild;
    expect(
      within(chrome).getByRole("heading", { name: "My Space" }),
    ).toBeInTheDocument();
    // The whole chrome is in there, not just the header: the environment card is
    // the tall thing that used to push the column past the viewport.
    expect(
      within(chrome).getByRole("button", { name: /Environment/ }),
    ).toBeInTheDocument();
    expect(chrome.className).toContain("overflow-y-auto");
    expect(chrome.className).toContain("min-h-0");
    // It scrolls; it never truncates what it holds.
    expect(chrome.className).not.toContain("overflow-hidden");

    // One scroll region, and it is the notes. `min-h-0` is load-bearing: without
    // it the pane keeps `min-height: auto`, stays at content height, its own
    // `overflow-y-auto` never engages, and the column's `overflow-hidden` clips
    // the newest notes out of reach.
    expect(panes(column)).toHaveLength(1);
    expect(panes(column)[0].className).toContain("overflow-y-auto");
    expect(panes(column)[0].className).toContain("min-h-0");

    // The composer is outside every scroll region and cannot be squeezed.
    const composer = screen.getByLabelText("Message").closest(".shrink-0");
    expect(composer).not.toBeNull();
    expect(chrome.contains(composer)).toBe(false);
    expect(panes(column)[0].contains(composer)).toBe(false);
    expect(column.contains(composer)).toBe(true);

    // The recipient picker is part of the composer's half of the page, not of
    // the chrome: it is the control that says who the next note is for, so it
    // may not be scrolled away from the input it applies to.
    const picker = screen.getByLabelText("Send to");
    expect(chrome.contains(picker)).toBe(false);
    expect(column.contains(picker)).toBe(true);
  });
});
