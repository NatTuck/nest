/**
 * Tests for `utils/spaceNote.js` — how a `user_notes` row reads to the human
 * whose feed it is.
 *
 * The wording is the header vocabulary the model reads (`agent <name>`,
 * `nest runtime`, `@nat`), and the two questions the page asks of a row are
 * "is this addressed to me" and "is it still waiting for me".
 */

import { describe, it, expect } from "vitest";
import {
  isIncoming,
  noteDirection,
  noteEnd,
  owedAgents,
  owedQueries,
} from "./spaceNote";

const note = (overrides) => ({
  id: 1,
  space_id: 1,
  from_kind: "agent",
  from_name: "boss",
  to_kind: "user",
  to_name: "alice",
  content: "hi",
  kind: "agent",
  answered_at: null,
  ...overrides,
});

describe("noteEnd", () => {
  it("names each kind of end the way a message header does", () => {
    expect(noteEnd("agent", "boss", "alice")).toBe("agent boss");
    expect(noteEnd("user", "alice", "alice")).toBe("you");
    expect(noteEnd("user", "bob", "alice")).toBe("@bob");
    expect(noteEnd("runtime", "boss", "alice")).toBe(
      "nest runtime (about boss)",
    );
    expect(noteEnd("runtime", null, "alice")).toBe("nest runtime");
  });

  it("says a human is @them even when the reader is not known yet", () => {
    // The page always knows who it is (the lobby's `currentUser`); when it does
    // not, the address is still the truth, just without "that's you".
    expect(noteEnd("user", "alice", null)).toBe("@alice");
  });

  it("says an unnamed agent is unnamed rather than rendering a blank", () => {
    expect(noteEnd("agent", null, "alice")).toBe("agent (unnamed)");
  });

  it("says an unnamed human is unnamed rather than rendering @null", () => {
    // `from_name` is nullable in the schema although every producer passes a
    // string today. `@null` would be a plausible-looking wrong address; the
    // project rule is that missing data gets a visible marker.
    expect(noteEnd("user", null, "alice")).toBe("a human (unnamed)");
    expect(noteEnd("user", "", "alice")).toBe("a human (unnamed)");
  });
});

describe("noteDirection", () => {
  it("reads as from … → …", () => {
    expect(noteDirection(note({}), "alice")).toBe("from agent boss → you");
    expect(
      noteDirection(
        note({
          from_kind: "user",
          from_name: "alice",
          to_kind: "agent",
          to_name: "boss",
        }),
        "alice",
      ),
    ).toBe("from you → agent boss");
  });
});

describe("isIncoming", () => {
  it("is about both ends, not just the kind", () => {
    // A note this human sent to another human is `to_kind: "user"` too.
    expect(isIncoming(note({}), "alice")).toBe(true);
    expect(
      isIncoming(
        note({
          from_kind: "user",
          from_name: "alice",
          to_kind: "user",
          to_name: "bob",
        }),
        "alice",
      ),
    ).toBe(false);
    expect(
      isIncoming(note({ to_kind: "agent", to_name: "boss" }), "alice"),
    ).toBe(false);
  });
});

describe("owedQueries", () => {
  it("is incoming queries that are still unanswered", () => {
    const notes = [
      note({ id: 1, kind: "query" }),
      note({ id: 2, kind: "query", answered_at: "2026-10-18T12:00:00Z" }),
      note({ id: 3, kind: "agent" }),
      note({ id: 4, kind: "query", to_kind: "agent", to_name: "boss" }),
      note({
        id: 5,
        kind: "query",
        from_kind: "user",
        from_name: "alice",
        to_kind: "user",
        to_name: "bob",
      }),
    ];

    expect(owedQueries(notes, "alice").map((held) => held.id)).toEqual([1]);
    // Nothing to read is not an error.
    expect(owedQueries(undefined, "alice")).toEqual([]);
  });
});

describe("owedAgents", () => {
  it("groups the outstanding queries by the agent that asked, in note order", () => {
    const notes = [
      note({ id: 1, kind: "query", from_name: "minion" }),
      note({ id: 2, kind: "query", from_name: "boss" }),
      note({ id: 3, kind: "query", from_name: "minion" }),
    ];

    expect(owedAgents(notes, "alice")).toEqual([
      { name: "minion", count: 2 },
      { name: "boss", count: 1 },
    ]);
  });

  it("leaves out a query from another human, who is not an agent to answer", () => {
    const notes = [
      note({
        id: 1,
        kind: "query",
        from_kind: "user",
        from_name: "bob",
        to_kind: "user",
        to_name: "alice",
      }),
      // An agent with no name cannot be selected as a recipient either.
      note({ id: 2, kind: "query", from_name: null }),
    ];

    expect(owedAgents(notes, "alice")).toEqual([]);
  });
});
