/**
 * Tests for the space feed's store slice: the notes at `/space/:slug`, per
 * space, and the three states that are not "no notes".
 *
 * The slice is the feed's whole cache, so these are the rules the page relies on:
 * a push and a read cannot show one note twice, a push for a space nobody opened
 * is dropped rather than cached forever, a refresh does not blank what is on
 * screen, and a failed read stays failed until the next attempt replaces it.
 */

import { describe, it, beforeEach, expect } from "vitest";
import { useStore } from "../index";

const note = (overrides) => ({
  id: 1,
  space_id: 1,
  from_kind: "agent",
  from_name: "boss",
  to_kind: "user",
  to_name: "alice",
  content: "hi",
  kind: "agent",
  inserted_at: "2026-10-18T12:00:00.000000Z",
  answered_at: null,
  ...overrides,
});

const feed = (spaceId = 1) => useStore.getState().spaceFeeds[spaceId];

describe("space feed slice", () => {
  beforeEach(() => {
    useStore.getState()._reset();
  });

  it("setSpaceFeed replaces the entry with the read's notes, modes and default", () => {
    useStore.getState().setSpaceFeed(1, {
      notes: [note({ id: 2 }), note({ id: 1 })],
      modes: ["plan", "act"],
      default_mode: "plan",
    });

    expect(feed()).toEqual({
      notes: [note({ id: 2 }), note({ id: 1 })],
      status: "ready",
      error: null,
      modes: ["plan", "act"],
      defaultMode: "plan",
    });
  });

  it("setSpaceFeed never invents a mode the server did not send", () => {
    // A missing default is `null`, which the selector renders as an explicit
    // unknown. A mode this client picked would be one nobody agreed to.
    useStore.getState().setSpaceFeed(1, {});

    expect(feed()).toMatchObject({ notes: [], modes: [], defaultMode: null });
  });

  it("setSpaceFeedLoading shows the loading state, but never blanks a feed already read", () => {
    // A first visit: there is nothing on screen yet.
    useStore.getState().setSpaceFeedLoading(1);
    expect(feed()).toMatchObject({ notes: [], status: "loading", error: null });

    // A retry after a failure: the error goes, the loading state shows.
    useStore.getState().setSpaceFeedError(1, "nope");
    useStore.getState().setSpaceFeedLoading(1);
    expect(feed()).toMatchObject({ status: "loading", error: null });

    // Revisiting a space keeps what the user was reading.
    useStore
      .getState()
      .setSpaceFeed(1, { notes: [note({})], modes: [], default_mode: "act" });
    useStore.getState().setSpaceFeedLoading(1);
    expect(feed().notes).toHaveLength(1);
    expect(feed().status).toBe("ready");
  });

  it("setSpaceFeedError says the read failed and keeps the reason", () => {
    useStore.getState().setSpaceFeed(1, { notes: [note({})], modes: ["act"] });
    useStore.getState().setSpaceFeedError(1, "Could not load the notes.");

    expect(feed()).toMatchObject({
      status: "error",
      error: "Could not load the notes.",
    });
  });

  it("setSpaceFeedError falls back to a sentence when it is given no reason", () => {
    useStore.getState().setSpaceFeedError(1, null);

    expect(feed().status).toBe("error");
    expect(feed().error).toEqual(expect.any(String));
  });

  it("appendSpaceNote adds a pushed note in id order and replaces a duplicate", () => {
    useStore
      .getState()
      .setSpaceFeed(1, { notes: [note({ id: 1 })], modes: [] });

    useStore.getState().appendSpaceNote(note({ id: 3, content: "third" }));
    useStore.getState().appendSpaceNote(note({ id: 2, content: "second" }));
    // The read that was already in flight also carried note 3: one row, not two.
    useStore
      .getState()
      .appendSpaceNote(note({ id: 3, content: "third, again" }));

    expect(feed().notes.map((held) => held.id)).toEqual([1, 2, 3]);
    expect(feed().notes[2].content).toBe("third, again");
  });

  it("appendSpaceNote drops a frame for a space whose feed was never opened", () => {
    // Nothing is showing it, and the first read of that space fetches the whole
    // list — including this note. Caching it would grow without a bound.
    useStore.getState().appendSpaceNote(note({ space_id: 42 }));

    expect(useStore.getState().spaceFeeds[42]).toBeUndefined();
  });

  it("appendSpaceNote ignores a frame that names no space or no note", () => {
    useStore.getState().setSpaceFeed(1, { notes: [], modes: [] });

    useStore.getState().appendSpaceNote({ id: 1 });
    useStore.getState().appendSpaceNote({ space_id: 1 });
    useStore.getState().appendSpaceNote(null);

    expect(feed().notes).toEqual([]);
  });

  it("markSpaceQueriesAnswered answers that agent's outstanding queries only", () => {
    useStore.getState().setSpaceFeed(1, {
      notes: [
        note({ id: 1, kind: "query", from_name: "boss" }),
        note({ id: 2, kind: "query", from_name: "boss" }),
        note({ id: 3, kind: "agent", from_name: "boss" }),
        note({ id: 4, kind: "query", from_name: "minion" }),
        note({
          id: 5,
          kind: "query",
          from_kind: "user",
          from_name: "alice",
          to_kind: "agent",
          to_name: "boss",
        }),
      ],
      modes: [],
    });

    useStore.getState().markSpaceQueriesAnswered(1, "boss");

    const answered = feed().notes.map((held) => Boolean(held.answered_at));
    // Boss's two queries are answered; a plain note from boss was not waiting,
    // another agent's query is untouched, and the note the human sent boss is
    // boss's to answer, not theirs.
    expect(answered).toEqual([true, true, false, false, false]);
  });

  it("markSpaceQueriesAnswered is a no-op for a space with no feed", () => {
    useStore.getState().markSpaceQueriesAnswered(42, "boss");

    expect(useStore.getState().spaceFeeds[42]).toBeUndefined();
  });
});
