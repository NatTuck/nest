/**
 * PanePanel tests: the open pane's frame and the two sections it holds.
 *
 * The indicator that stands in for it while it is closed is `PaneToggle`, in the
 * tab bar's trailing slot (#169), and is tested there. The rule that decides
 * whether the pane is open at all — closed by default, opened when a question is
 * asked — is `setPaneState/2`'s and is pinned in the slice's tests; what this
 * file checks is that the panel renders nothing at all while it is closed.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { PanePanel } from "./PanePanel";
import { useStore } from "../../store";

vi.mock("../../channels", () => ({
  sendDecisionAnswers: vi.fn(),
  dropDecisions: vi.fn(),
  explainDecision: vi.fn(),
}));

const SPACE = 7;
const NAME = "agent-1";

const decision = (overrides) => ({
  id: "d1",
  title: "Ship or wait?",
  body: "body of the question",
  options: ["Ship", "Wait"],
  askedBy: "boss",
  obsolete: false,
  obsoleteReason: null,
  orphaned: false,
  orphanedReason: null,
  ...overrides,
});

const first = decision({ id: "d1", title: "First" });
const second = decision({ id: "d2", title: "Second" });
const third = decision({ id: "d3", title: "Third" });

function seedPane(overrides = {}) {
  useStore.setState({
    panes: {
      [SPACE]: {
        decisions: [],
        todos: {},
        seq: 1,
        collapsed: false,
        expandedId: null,
        drafts: {},
        marks: {},
        outcomes: {},
        error: null,
        ...overrides,
      },
    },
  });
}

function renderPane() {
  return render(<PanePanel name={NAME} spaceId={SPACE} />);
}

describe("PanePanel", () => {
  beforeEach(() => {
    cleanup();
    useStore.getState()._reset();
    vi.clearAllMocks();
  });

  it("renders nothing until the first frame for the space arrives", () => {
    // Nothing has said the pane has anything in it, and an empty column would
    // shove the chat sideways the moment the frame landed.
    const { container } = renderPane();

    expect(container.firstChild).toBeNull();
  });

  it("shows the open agent's TODO items with their statuses, and the questions", () => {
    seedPane({
      decisions: [first],
      todos: {
        [NAME]: [
          { text: "write the tests", status: "in_progress" },
          { text: "ship it", status: "done" },
          { text: "tell the user", status: "pending" },
        ],
        "other-agent": [{ text: "not this page's list", status: "pending" }],
      },
    });

    renderPane();

    expect(screen.getByText("TODO (3)")).toBeInTheDocument();
    expect(screen.getByText("write the tests")).toBeInTheDocument();
    expect(screen.getByText("in progress")).toBeInTheDocument();
    expect(
      screen.getByText("1 pending · 1 in progress · 1 done"),
    ).toBeInTheDocument();
    // The pane shows the agent whose page is open, not every agent's list.
    expect(screen.queryByText("not this page's list")).toBeNull();
    // The questions are in the same pane, above or below the TODO list.
    expect(screen.getByText("First")).toBeInTheDocument();
  });

  it("calls out a TODO item whose status it does not know", () => {
    seedPane({
      todos: {
        [NAME]: [
          { text: "mystery", status: "sideways" },
          { text: "no status" },
        ],
      },
    });

    renderPane();

    const chips = screen.getAllByTestId("todo-unknown-status");
    expect(chips[0]).toHaveTextContent("unknown: sideways");
    // A missing status is not silently rendered as `pending`.
    expect(chips[1]).toHaveTextContent("(no status)");
  });

  it("says whether the agent has no items or the payload lost the map", () => {
    seedPane({ todos: {} });
    const { unmount } = renderPane();
    expect(screen.getByText(`No TODO items for ${NAME}.`)).toBeInTheDocument();
    unmount();

    // The wire always carries the map, so a frame without one is a contract
    // violation rather than "no TODOs".
    seedPane({ todos: null });
    renderPane();
    expect(screen.getByTestId("todo-missing")).toBeInTheDocument();
  });

  it("opens when a question is asked, and stays shut for a frame that only repeats", () => {
    seedPane({ decisions: [first, second] });

    renderPane();
    expect(screen.getByLabelText("Questions and TODO")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Hide pane" }));

    // Closed: the panel renders nothing. The way back in is `PaneToggle`, which
    // is not this component (see `PaneToggle.test.jsx`).
    expect(screen.queryByLabelText("Questions and TODO")).toBeNull();

    // A frame that only repeats the questions already on screen does not reopen
    // it — otherwise closing the pane would be undone by the next unrelated
    // frame, and a user who is not ready to answer could not dismiss it.
    act(() => {
      useStore.getState().setPaneState(SPACE, {
        seq: 2,
        decisions: [first, second],
        todos: {},
      });
    });

    expect(screen.queryByLabelText("Questions and TODO")).toBeNull();

    // A question that was not on screen is one being asked now, and that opens
    // the pane (issue #169).
    act(() => {
      useStore.getState().setPaneState(SPACE, {
        seq: 3,
        decisions: [first, second, third],
        todos: {},
      });
    });

    expect(screen.getByLabelText("Questions and TODO")).toBeInTheDocument();
  });
});
