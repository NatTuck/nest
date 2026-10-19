/**
 * DecisionsAccordion tests: the accordion's open row and its advance, the
 * save/drop marks, what "send answers" posts, and the three states a question
 * can be in besides open (obsolete, orphaned, refused).
 *
 * The last two tests are the UI rule from issue #119: a frame that brings a new
 * question may append it and nothing else — it must not reorder the list, move
 * the open row, or take focus out of a half-typed answer.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { DecisionsAccordion } from "./DecisionsAccordion";
import { useStore } from "../../store";

// The pushes are the pane's only side effects; every assertion about "send
// answers" is about exactly what it posts.
const channels = vi.hoisted(() => ({
  sendDecisionAnswers: vi.fn(),
  dropDecisions: vi.fn(),
  explainDecision: vi.fn(),
}));
vi.mock("../../channels", () => channels);

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

const first = decision({ id: "d1", title: "First", body: "body of First" });
const second = decision({ id: "d2", title: "Second", body: "body of Second" });
const third = decision({ id: "d3", title: "Third", body: "body of Third" });

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

function renderAccordion() {
  return render(<DecisionsAccordion name={NAME} spaceId={SPACE} />);
}

const title = (name) => screen.getByRole("button", { name });

describe("DecisionsAccordion", () => {
  beforeEach(() => {
    cleanup();
    useStore.getState()._reset();
    vi.clearAllMocks();
  });

  it("shows every title, opens the top question, and opens another on a click", () => {
    seedPane({ decisions: [first, second, third] });

    renderAccordion();

    expect(title(/First/)).toHaveAttribute("aria-expanded", "true");
    expect(title(/Second/)).toHaveAttribute("aria-expanded", "false");
    expect(title(/Third/)).toHaveAttribute("aria-expanded", "false");
    // Only the open question renders its body, so a long list stays readable.
    expect(screen.getByText("body of First")).toBeInTheDocument();
    expect(screen.queryByText("body of Second")).toBeNull();
    // The open row says so on its title.
    expect(screen.getAllByText("open")).toHaveLength(1);

    fireEvent.click(title(/Second/));

    expect(title(/Second/)).toHaveAttribute("aria-expanded", "true");
    expect(title(/First/)).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByText("body of Second")).toBeInTheDocument();
    expect(screen.queryByText("body of First")).toBeNull();
  });

  it("contracts a saved question, marks it saved, and opens the next one, looping", () => {
    seedPane({ decisions: [first, second] });

    renderAccordion();

    fireEvent.click(screen.getByRole("button", { name: "Ship" }));
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(screen.getAllByText("saved")).toHaveLength(1);
    // It contracted, and the question below it opened.
    expect(title(/First/)).toHaveAttribute("aria-expanded", "false");
    expect(title(/Second/)).toHaveAttribute("aria-expanded", "true");

    fireEvent.click(screen.getByRole("button", { name: "Ship" }));
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    // The end of the list loops back to the first question, which is where the
    // user's next answer would go.
    expect(screen.getAllByText("saved")).toHaveLength(2);
    expect(title(/Second/)).toHaveAttribute("aria-expanded", "false");
    expect(title(/First/)).toHaveAttribute("aria-expanded", "true");
  });

  it("keeps a save depressed until the answer changes or the answers are sent", () => {
    seedPane({ decisions: [decision({})] });

    renderAccordion();

    const save = () => screen.getByRole("button", { name: "Save" });
    // Nothing to save yet: an empty answer is not an answer.
    expect(save()).toBeDisabled();

    fireEvent.click(screen.getByRole("button", { name: "Ship" }));
    fireEvent.click(save());
    expect(save()).toHaveAttribute("aria-pressed", "true");

    // The mark described "Ship"; the answer is now "Wait", so it is not
    // resolved any more.
    fireEvent.click(screen.getByRole("button", { name: "Wait" }));
    expect(save()).toHaveAttribute("aria-pressed", "false");

    fireEvent.click(save());
    expect(save()).toHaveAttribute("aria-pressed", "true");

    fireEvent.click(screen.getByRole("button", { name: /Send answers/ }));

    // Pressing send releases the marks it just posted.
    expect(save()).toHaveAttribute("aria-pressed", "false");
    expect(channels.sendDecisionAnswers).toHaveBeenCalledWith(NAME, SPACE, [
      { id: "d1", answer: "Wait" },
    ]);
  });

  it("posts exactly the saved answers and the dropped ids, and nothing for the rest", () => {
    seedPane({
      decisions: [first, second, third],
      drafts: { d1: "  Ship it  " },
      marks: { d1: "save", d2: "drop" },
    });

    renderAccordion();

    expect(
      screen.getByRole("button", { name: "Send answers (2)" }),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Send answers/ }));

    expect(channels.sendDecisionAnswers).toHaveBeenCalledTimes(1);
    expect(channels.sendDecisionAnswers).toHaveBeenCalledWith(NAME, SPACE, [
      { id: "d1", answer: "Ship it" },
    ]);
    expect(channels.dropDecisions).toHaveBeenCalledTimes(1);
    expect(channels.dropDecisions).toHaveBeenCalledWith(NAME, SPACE, ["d2"]);
    // The untouched question is in neither push.
    expect(screen.getByRole("button", { name: "Send answers" })).toBeDisabled();
  });

  it("shows an obsolete question's reason and still lets the user answer it", () => {
    seedPane({
      decisions: [
        decision({
          obsolete: true,
          obsoleteReason: "the worker already did this",
        }),
      ],
    });

    renderAccordion();

    expect(screen.getByTestId("decision-obsolete")).toHaveTextContent(
      "the worker already did this",
    );
    expect(screen.getByLabelText("Your answer")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Drop" })).toBeInTheDocument();
  });

  it("renders an orphaned question drop-only, with the reason", () => {
    seedPane({
      decisions: [
        decision({
          orphaned: true,
          orphanedReason: "agent boss was archived",
        }),
      ],
    });

    renderAccordion();

    expect(screen.getByTestId("decision-orphaned")).toHaveTextContent(
      "agent boss was archived",
    );
    // Nothing can deliver an answer to an agent that is gone, so there is no
    // answer field, no save and nothing to ask for detail.
    expect(screen.queryByLabelText("Your answer")).toBeNull();
    expect(screen.queryByRole("button", { name: "Save" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Explain more" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Drop" }));
    expect(screen.getByRole("button", { name: "Drop" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    fireEvent.click(screen.getByRole("button", { name: /Send answers/ }));

    expect(channels.dropDecisions).toHaveBeenCalledWith(NAME, SPACE, ["d1"]);
    expect(channels.sendDecisionAnswers).not.toHaveBeenCalled();
  });

  it("keeps a refused answer answerable and says why it did not land", () => {
    seedPane({ decisions: [decision({})] });

    renderAccordion();

    fireEvent.click(screen.getByRole("button", { name: "Ship" }));
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    fireEvent.click(screen.getByRole("button", { name: /Send answers/ }));

    act(() => {
      useStore.getState().applyPaneAnswerReply(SPACE, {
        delivered: [],
        orphaned: [],
        failed: [{ id: "d1", reason: "the agent is busy" }],
      });
    });

    expect(screen.getByTestId("decision-failed")).toHaveTextContent(
      "the agent is busy",
    );
    // A transient refusal, so the answer is still there to send again.
    expect(screen.getByLabelText("Your answer")).toHaveValue("Ship");
  });

  it("asks for more detail on the open question and leaves it open", () => {
    seedPane({ decisions: [decision({})] });

    renderAccordion();

    fireEvent.click(screen.getByRole("button", { name: "Explain more" }));

    expect(channels.explainDecision).toHaveBeenCalledWith(NAME, SPACE, "d1");
    expect(title(/Ship or wait\?/)).toHaveAttribute("aria-expanded", "true");
  });

  it("says so when a question arrived without the parts it needs", () => {
    seedPane({
      decisions: [
        decision({ options: undefined, body: "", title: "", askedBy: null }),
      ],
    });

    renderAccordion();

    expect(screen.getByTestId("decision-options-missing")).toBeInTheDocument();
    expect(screen.getByText("(no explanation was given)")).toBeInTheDocument();
    expect(screen.getByText("(untitled question)")).toBeInTheDocument();
    expect(screen.getByText(/\(an unidentified agent\)/)).toBeInTheDocument();
  });

  it("says an orphaned question's reason is missing instead of leaving it blank", () => {
    seedPane({
      decisions: [
        decision({
          id: "d1",
          title: "Gone",
          orphaned: true,
          orphanedReason: null,
        }),
      ],
    });

    renderAccordion();

    expect(screen.getByTestId("decision-orphaned")).toHaveTextContent(
      "no reason was given",
    );
  });

  it("appends a new question without reordering, re-expanding, or stealing focus", () => {
    seedPane({ decisions: [first, second] });

    const { container } = renderAccordion();

    fireEvent.click(title(/Second/));
    const textarea = screen.getByLabelText("Your answer");
    fireEvent.change(textarea, { target: { value: "half-typed" } });
    textarea.focus();
    expect(document.activeElement).toBe(textarea);

    act(() => {
      // The server's frame, listing the new question first: the pane must keep
      // the order the user has been reading and append it.
      useStore.getState().setPaneState(SPACE, {
        seq: 2,
        decisions: [third, first, second],
        todos: {},
      });
    });

    const order = [...container.querySelectorAll("ol > li")].map(
      (row) => row.textContent,
    );
    expect(order).toHaveLength(3);
    expect(order[0]).toContain("First");
    expect(order[1]).toContain("Second");
    expect(order[2]).toContain("Third");

    // The row the user opened is still the open one, the new one did not steal
    // it, and the half-typed answer still has the focus.
    expect(title(/Second/)).toHaveAttribute("aria-expanded", "true");
    expect(title(/Third/)).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByLabelText("Your answer")).toBe(textarea);
    expect(textarea).toHaveValue("half-typed");
    expect(document.activeElement).toBe(textarea);
  });
});
