/**
 * Tests for the pane's store slice: the frame reconcile, the `seq` guard that
 * keeps a late frame from resurrecting a question, the browser-owned state that
 * has to survive a frame, and the answer reply's outcomes.
 *
 * The rules the pane relies on, in one place: a frame never reorders the list on
 * screen, never applies over a newer frame, never loses the user's collapse /
 * open row / drafts / marks, and never removes a question — the server's frame
 * is the only removal.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import { useStore } from "../index";
import { outstandingCount } from "./pane";

const SPACE = 7;

const decision = (overrides) => ({
  id: "d1",
  title: "Ship or wait?",
  body: "Shipping early risks bugs.",
  options: ["Ship", "Wait"],
  askedBy: "boss",
  obsolete: false,
  obsoleteReason: null,
  orphaned: false,
  orphanedReason: null,
  ...overrides,
});

const frame = (seq, decisions, todos = {}) => ({
  spaceId: SPACE,
  decisions,
  todos,
  seq,
});

const pane = () => useStore.getState().panes[SPACE];
const ids = () => (pane()?.decisions ?? []).map((held) => held.id);

describe("pane slice", () => {
  beforeEach(() => {
    useStore.getState()._reset();
    vi.restoreAllMocks();
  });

  it("reconciles a frame against the list on screen instead of replacing it", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [decision({ id: "d1" }), decision({ id: "d2" })]),
      );

    // The frame names d2 first, updates it, drops d1 and adds d3. A wholesale
    // replace would move d2 up the pane and put d3 above it.
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(2, [
          decision({ id: "d3", title: "Third" }),
          decision({ id: "d2", title: "Second, updated" }),
        ]),
      );

    expect(ids()).toEqual(["d2", "d3"]);
    expect(pane().decisions[0].title).toBe("Second, updated");
    expect(pane().seq).toBe(2);
  });

  it("drops a frame whose seq is not newer, so a late frame cannot bring a question back", () => {
    useStore.getState().setPaneState(SPACE, frame(5, [decision({ id: "d1" })]));
    // The user answered it, and the server's frame without it is the removal.
    useStore.getState().setPaneState(SPACE, frame(6, []));
    expect(ids()).toEqual([]);

    // A frame from before the answer: older, and then exactly the same seq.
    useStore.getState().setPaneState(SPACE, frame(5, [decision({ id: "d1" })]));
    expect(ids()).toEqual([]);
    useStore.getState().setPaneState(SPACE, frame(6, [decision({ id: "d1" })]));
    expect(ids()).toEqual([]);

    // A newer frame is applied, so the guard cannot wedge the pane shut.
    useStore.getState().setPaneState(SPACE, frame(7, [decision({ id: "d1" })]));
    expect(ids()).toEqual(["d1"]);
  });

  // Issue #169: the pane is closed by default, opens when a question is asked,
  // and never closes itself.
  describe("when the pane is open", () => {
    it("starts closed, and opens on the first frame when something is waiting", () => {
      useStore.getState().setPaneState(SPACE, frame(1, []));

      // Nothing waiting: closed, with the toggle as the way in.
      expect(pane().collapsed).toBe(true);

      // A space with a question already asked arrives open — a closed pane over
      // an unanswered question would look empty rather than quiet.
      useStore.getState()._reset();
      useStore
        .getState()
        .setPaneState(SPACE, frame(1, [decision({ id: "d1" })]));

      expect(pane().collapsed).toBe(false);
    });

    it("opens when a frame brings a question it was not already showing", () => {
      useStore
        .getState()
        .setPaneState(SPACE, frame(1, [decision({ id: "d1" })]));

      useStore.getState().setPaneCollapsed(SPACE, true);
      expect(pane().collapsed).toBe(true);

      // A question that was not on screen is one being asked now.
      useStore
        .getState()
        .setPaneState(
          SPACE,
          frame(2, [decision({ id: "d1" }), decision({ id: "d2" })]),
        );

      expect(pane().collapsed).toBe(false);
    });

    it("stays closed for a frame that only repeats what is on screen", () => {
      useStore
        .getState()
        .setPaneState(SPACE, frame(1, [decision({ id: "d1" })]));

      useStore.getState().setPaneCollapsed(SPACE, true);

      // Same question, new `seq`: nothing was asked, so the user's close stands.
      useStore
        .getState()
        .setPaneState(SPACE, frame(2, [decision({ id: "d1" })]));

      expect(pane().collapsed).toBe(true);

      // A TODO-only change is not a question either.
      useStore.getState().setPaneState(
        SPACE,
        frame(3, [decision({ id: "d1" })], {
          boss: [{ text: "x", status: "pending" }],
        }),
      );

      expect(pane().collapsed).toBe(true);
    });
  });

  it("keeps the browser's own state across a frame and prunes it for the questions the frame dropped", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [decision({ id: "d1" }), decision({ id: "d2" })]),
      );

    const store = useStore.getState();
    store.setPaneCollapsed(SPACE, true);
    store.setPaneExpanded(SPACE, "d2");
    store.setPaneDraft(SPACE, "d1", "Ship");
    store.markPaneDecision(SPACE, "d1", "save");

    useStore.getState().setPaneState(SPACE, frame(2, [decision({ id: "d2" })]));

    expect(pane().collapsed).toBe(true);
    expect(pane().expandedId).toBe("d2");
    // d1 is gone, so nothing may still hold its half-typed answer or its mark.
    expect(pane().drafts).toEqual({});
    expect(pane().marks).toEqual({});
  });

  it("marking a question opens the next unanswered one, looping at the end", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [
          decision({ id: "d1" }),
          decision({ id: "d2" }),
          decision({ id: "d3" }),
        ]),
      );

    useStore.getState().markPaneDecision(SPACE, "d2", "save");
    // d3 is next, not d1: the advance goes forward from the resolved question.
    expect(pane().expandedId).toBe("d3");

    useStore.getState().markPaneDecision(SPACE, "d3", "drop");
    // Wrapping past the end lands on the one still unanswered.
    expect(pane().expandedId).toBe("d1");

    useStore.getState().markPaneDecision(SPACE, "d1", "save");
    // Every question is resolved: the row below it (looping) stays open rather
    // than leaving the accordion with nothing expanded.
    expect(pane().expandedId).toBe("d2");
  });

  it("advances past a drop-only question rather than opening it", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [
          decision({ id: "d1" }),
          decision({ id: "d2", orphaned: true, orphanedReason: "gone" }),
          decision({ id: "d3" }),
        ]),
      );

    useStore.getState().markPaneDecision(SPACE, "d1", "save");

    // d2 carries no mark — nothing can be saved for it — but it is drop-only,
    // so opening it would put a row with one control where the user's next
    // answer should go.
    expect(pane().expandedId).toBe("d3");

    useStore.getState().markPaneDecision(SPACE, "d3", "save");

    // Nothing is answerable any more, so the row below the resolved one
    // (looping) stays open rather than leaving the accordion closed.
    expect(pane().expandedId).toBe("d1");
  });

  it("an answer change clears the mark, because the mark described the old answer", () => {
    useStore.getState().setPaneState(SPACE, frame(1, [decision({ id: "d1" })]));
    useStore.getState().setPaneDraft(SPACE, "d1", "Ship");
    useStore.getState().markPaneDecision(SPACE, "d1", "save");
    expect(pane().marks).toEqual({ d1: "save" });

    useStore.getState().setPaneDraft(SPACE, "d1", "Ship it tomorrow");

    expect(pane().marks).toEqual({});
    expect(pane().drafts.d1).toBe("Ship it tomorrow");
  });

  it("applies an answer reply's outcomes without removing anything itself", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [
          decision({ id: "d1" }),
          decision({ id: "d2" }),
          decision({ id: "d3" }),
          decision({ id: "d4" }),
        ]),
      );

    const store = useStore.getState();
    for (const id of ["d1", "d2", "d3", "d4"]) {
      store.setPaneDraft(SPACE, id, "yes");
      store.markPaneDecision(SPACE, id, "save");
    }

    store.applyPaneAnswerReply(SPACE, {
      delivered: ["d1"],
      orphaned: [{ id: "d2", reason: "agent boss was archived" }],
      failed: [{ id: "d3", reason: "the agent is busy" }],
      lost: [{ id: "d4", reason: "agent boss vanished" }],
    });

    // The list is the server's: this client did not remove the delivered
    // question, it waits for the frame that no longer carries it.
    expect(ids()).toEqual(["d1", "d2", "d3", "d4"]);
    expect(pane().marks).toEqual({});
    expect(pane().drafts.d1).toBeUndefined();
    // A question that turned out orphaned can only be dropped now; a refused
    // one is still answerable, so its draft is kept for another try.
    expect(pane().outcomes.d2).toEqual({
      kind: "orphaned",
      reason: "agent boss was archived",
    });
    expect(pane().outcomes.d3).toEqual({
      kind: "failed",
      reason: "the agent is busy",
    });
    expect(pane().drafts.d3).toBe("yes");
    // Lost: the question went with the answer, so neither its mark nor its
    // draft has anything left to describe.
    expect(pane().outcomes.d4).toEqual({
      kind: "lost",
      reason: "agent boss vanished",
    });
    expect(pane().drafts.d4).toBeUndefined();
  });

  it("counts only the questions that carry no mark as outstanding", () => {
    useStore
      .getState()
      .setPaneState(
        SPACE,
        frame(1, [
          decision({ id: "d1" }),
          decision({ id: "d2" }),
          decision({ id: "d3" }),
        ]),
      );
    useStore.getState().markPaneDecision(SPACE, "d1", "drop");

    expect(outstandingCount(pane())).toBe(2);
    // Nothing has arrived for that space at all, which is not the same as a
    // pane with nothing outstanding.
    expect(outstandingCount(undefined)).toBe(0);
  });

  it("is a no-op for a space with no pane yet, and for a mark that is not a mark", () => {
    const store = useStore.getState();

    // Every setter can be reached before the first frame exists (the controls
    // only appear with the entry, but a stray event or a test double can still
    // call one); none of them may invent a pane.
    store.setPaneCollapsed(SPACE, true);
    store.setPaneExpanded(SPACE, "d1");
    store.setPaneDraft(SPACE, "d1", "Ship");
    store.markPaneDecision(SPACE, "d1", "save");
    store.clearPaneMarks(SPACE);
    store.applyPaneAnswerReply(SPACE, { delivered: ["d1"] });
    store.setPaneExplained(SPACE, "d1");
    store.setPaneError(SPACE, "nope");

    expect(useStore.getState().panes[SPACE]).toBeUndefined();

    store.setPaneState(SPACE, frame(1, [decision({ id: "d1" })]));
    // A mark the pane has no rendering for would be state nothing can undo.
    store.markPaneDecision(SPACE, "d1", "maybe");

    expect(pane().marks).toEqual({});
  });

  it("refuses a frame it cannot address rather than guessing", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    // No sequence: there is no way to tell whether this is newer than what is
    // on screen.
    useStore
      .getState()
      .setPaneState(SPACE, { decisions: [decision({ id: "d1" })], todos: {} });
    // A question with no id cannot be keyed, reconciled or acted on.
    useStore
      .getState()
      .setPaneState(SPACE, frame(1, [{ title: "no id here" }]));

    expect(pane()).toBeUndefined();
    expect(warn).toHaveBeenCalledTimes(2);

    warn.mockRestore();
  });
});
