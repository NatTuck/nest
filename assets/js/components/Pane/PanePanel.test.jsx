/**
 * PanePanel tests: the pane's frame, the two sections it holds, and the
 * notification-style indicator it leaves behind when the user closes it.
 *
 * The count on that indicator is the pane's whole reason for existing while it
 * is closed, so it is tested for what it excludes — a question the user has
 * already marked is not waiting for them — and for the UI rule: a frame that
 * brings a new question updates the count and must not reopen the pane.
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

  it("closes the pane and counts the outstanding questions in the indicator", () => {
    seedPane({ decisions: [first, second] });

    renderPane();
    expect(screen.getByLabelText("Questions and TODO")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Hide pane" }));

    expect(screen.queryByLabelText("Questions and TODO")).toBeNull();
    expect(
      screen.getByRole("button", { name: "2 questions" }),
    ).toBeInTheDocument();

    act(() => {
      useStore.getState().setPaneState(SPACE, {
        seq: 2,
        decisions: [first, second, third],
        todos: {},
      });
    });

    // The count follows the frame, and the pane stays closed: opening it is the
    // user's decision, never a frame's.
    expect(
      screen.getByRole("button", { name: "3 questions" }),
    ).toBeInTheDocument();
    expect(screen.queryByLabelText("Questions and TODO")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "3 questions" }));

    expect(screen.getByLabelText("Questions and TODO")).toBeInTheDocument();
  });

  it("counts only the questions still waiting, and leaves no indicator when none are", () => {
    seedPane({
      decisions: [first, second],
      collapsed: true,
      marks: { d1: "save" },
    });

    const { container } = renderPane();

    expect(
      screen.getByRole("button", { name: "1 question" }),
    ).toBeInTheDocument();

    act(() => {
      useStore.getState().markPaneDecision(SPACE, "d2", "drop");
    });

    // Nothing is waiting for the user any more, so there is nothing to point at.
    expect(container.firstChild).toBeNull();
  });
});
