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
  queryReplyState,
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
  dismissed_at: null,
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
  it("is incoming queries that are still unanswered and not ignored", () => {
    const notes = [
      note({ id: 1, kind: "query" }),
      note({ id: 2, kind: "query", answered_at: "2026-10-18T12:00:00Z" }),
      // Ignored: the human decided not to answer, which is not the same as
      // still owing one — and not the same as having answered.
      note({ id: 6, kind: "query", dismissed_at: "2026-10-18T12:02:00Z" }),
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
      { name: "minion", count: 2, ids: [1, 3] },
      { name: "boss", count: 1, ids: [2] },
    ]);
  });

  it("leaves out an archived agent, which owes nothing anyone can answer", () => {
    // An archived agent's process is stopped: its query is still a row in the
    // feed, but there is no turn to answer from this page and no note the human
    // could send that would clear it.
    const notes = [
      note({ id: 1, kind: "query", from_name: "retired" }),
      note({ id: 2, kind: "query", from_name: "boss" }),
    ];

    expect(owedAgents(notes, "alice", new Set(["retired"]))).toEqual([
      { name: "boss", count: 1, ids: [2] },
    ]);
    // With nothing archived, nothing changes.
    expect(owedAgents(notes, "alice")).toEqual([
      { name: "retired", count: 1, ids: [1] },
      { name: "boss", count: 1, ids: [2] },
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

describe("queryReplyState", () => {
  it("tells an answered query from one that is still owed, and from an archived agent's", () => {
    // The five states the card renders. The archived one is the case the banner
    // and the card used to disagree about: the row is unanswered, so the card
    // keeps saying so, but the agent is stopped, so nothing is owed.
    expect(queryReplyState(note({ kind: "query" }), "alice")).toBe("owed");
    // Ignored: the human's own decision, so it outranks the agent's status —
    // there is nothing to reply to and nothing to keep asking about.
    expect(
      queryReplyState(
        note({ kind: "query", dismissed_at: "2026-10-18T12:02:00Z" }),
        "alice",
      ),
    ).toBe("dismissed");
    expect(
      queryReplyState(
        note({
          kind: "query",
          dismissed_at: "2026-10-18T12:02:00Z",
          from_name: "retired",
        }),
        "alice",
        new Set(["retired"]),
      ),
    ).toBe("dismissed");
    expect(
      queryReplyState(
        note({ kind: "query", answered_at: "2026-10-18T12:01:00Z" }),
        "alice",
      ),
    ).toBe("answered");
    expect(
      queryReplyState(
        note({ kind: "query", from_name: "retired" }),
        "alice",
        new Set(["retired"]),
      ),
    ).toBe("archived");
    // A query the human sent is waiting for the other end, not for them.
    expect(
      queryReplyState(
        note({ kind: "query", to_kind: "agent", to_name: "boss" }),
        "alice",
      ),
    ).toBe("awaiting");
  });

  it("only calls an agent's own query archived", () => {
    // A human with the same name as an archived agent is not an agent, so the
    // archived set does not apply to their note: the reply is the human's to
    // give and the card must keep asking for it.
    const fromHuman = note({
      kind: "query",
      from_kind: "user",
      from_name: "retired",
    });

    expect(queryReplyState(fromHuman, "alice", new Set(["retired"]))).toBe(
      "owed",
    );
  });
});
