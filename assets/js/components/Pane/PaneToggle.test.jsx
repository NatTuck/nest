/**
 * PaneToggle tests: the control that opens the right-hand pane (#169).
 *
 * It is the page's *default* state — the pane starts closed — so what matters is
 * that it is always there while the pane is closed, that its count is the
 * notification (and counts only what is actually waiting), and that it takes no
 * column of its own: it renders into the tab bar's trailing slot, not beside the
 * conversation.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { PaneToggle } from "./PaneToggle";
import { useStore } from "../../store";

vi.mock("../../channels", () => ({
  sendDecisionAnswers: vi.fn(),
  dropDecisions: vi.fn(),
  explainDecision: vi.fn(),
}));

const SPACE = 7;

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

function seedPane(overrides = {}) {
  useStore.setState({
    panes: {
      [SPACE]: {
        decisions: [],
        todos: {},
        seq: 1,
        collapsed: true,
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

const renderToggle = () => render(<PaneToggle spaceId={SPACE} />);
const pane = () => useStore.getState().panes[SPACE];

describe("PaneToggle", () => {
  beforeEach(() => {
    useStore.getState()._reset();
    vi.restoreAllMocks();
  });

  it("is absent until a frame arrives", () => {
    // No frame for this space: there is no pane to offer a control over.
    renderToggle();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("is absent while the pane is open", () => {
    seedPane({ collapsed: false });

    renderToggle();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("counts the questions still waiting, and keeps a way back in when none are", () => {
    seedPane({ decisions: [first, second], marks: { d1: "save" } });

    renderToggle();

    // The count is the notification: a question the user has already marked is
    // not waiting for them.
    expect(
      screen.getByRole("button", { name: "1 question" }),
    ).toBeInTheDocument();

    act(() => {
      useStore.getState().markPaneDecision(SPACE, "d2", "drop");
    });

    // Nothing is waiting any more, so the notification stops — but the control
    // must not: it is the only way back into a closed pane, and a pane that
    // cannot be reopened hides every TODO list written after it.
    expect(
      screen.queryByRole("button", { name: /question/ }),
    ).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Pane" }));

    expect(pane().collapsed).toBe(false);
  });

  it("opens the pane when it is clicked", () => {
    seedPane({ decisions: [first] });

    renderToggle();
    fireEvent.click(screen.getByRole("button", { name: "1 question" }));

    expect(pane().collapsed).toBe(false);
  });
});
