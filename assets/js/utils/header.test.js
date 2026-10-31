/**
 * Tests for the `[From … | mode: …]` header: its grammar, the affordances that
 * give its facts a home, and the removal that is only allowed because of them.
 *
 * The rule under test: a marker is wire framing only when the fact it carries
 * is rendered somewhere else, and the *same parse* decides both. So a header
 * line is dropped only when `parseHeaderLine` read it and its mode agrees with
 * the message's own — and `splitFraming` hands the parsed facts back, which is
 * what the row label and the per-body captions are built from.
 */
import { describe, expect, it } from "vitest";

import {
  AGENT_LABEL_OPEN,
  NOTICE_TAG,
  parseHeaderLine,
  rowAppearance,
  rowSenders,
  senderClass,
  senderLabel,
} from "./header.js";
import { splitFraming, stripRetiredMarkers } from "./stripHeader.js";

const human = { kind: "human", name: null };
const nat = { kind: "human", name: "nat" };
const agent = (name = null) => ({ kind: "agent", name });
const runtime = { kind: "runtime", name: null };
const unknown = { kind: "unknown", name: null };

describe("parseHeaderLine", () => {
  // The seven shapes `Nest.Messages.Header.line/3` writes, in the order its
  // moduledoc lists them.
  it("parses every shape the server writes", () => {
    expect(parseHeaderLine("[From user | mode: act]")).toEqual({
      sender: human,
      replyRequired: false,
      mode: "act",
    });

    expect(parseHeaderLine("[From user @nat | mode: act]")).toEqual({
      sender: nat,
      replyRequired: false,
      mode: "act",
    });

    expect(
      parseHeaderLine(
        "[From user @nat, agents-send reply required | mode: act]",
      ),
    ).toEqual({ sender: nat, replyRequired: true, mode: "act" });

    expect(parseHeaderLine("[From agent crazy-dolphin | mode: plan]")).toEqual({
      sender: agent("crazy-dolphin"),
      replyRequired: false,
      mode: "plan",
    });

    expect(
      parseHeaderLine(
        "[From agent crazy-dolphin, agents-send reply required | mode: plan]",
      ),
    ).toEqual({
      sender: agent("crazy-dolphin"),
      replyRequired: true,
      mode: "plan",
    });

    expect(parseHeaderLine("[From nest runtime | mode: act]")).toEqual({
      sender: runtime,
      replyRequired: false,
      mode: "act",
    });

    // The compaction request's mode is not one the operator can select, which is
    // what made it easy to overlook.
    expect(parseHeaderLine("[From nest runtime | mode: compact]")).toEqual({
      sender: runtime,
      replyRequired: false,
      mode: "compact",
    });
  });

  it("parses the header's name-less shapes", () => {
    // `Header.who/1` writes a bare `user` / `agent` when the producer has no
    // name. The row must not read as the other class, and printing `nil` would
    // be worse than leaving the name out.
    expect(parseHeaderLine("[From agent | mode: act]")).toEqual({
      sender: agent(),
      replyRequired: false,
      mode: "act",
    });
  });

  it("returns null for a line that is not a header", () => {
    expect(parseHeaderLine("hello")).toBeNull();
    expect(parseHeaderLine("[nest notice]")).toBeNull();
    expect(parseHeaderLine('[Message from agent "peer"]')).toBeNull();
    expect(parseHeaderLine("")).toBeNull();
    expect(parseHeaderLine(null)).toBeNull();
    expect(parseHeaderLine(42)).toBeNull();
  });

  it("returns null for a header whose sender class it does not know", () => {
    // A shape this build does not write is not framing: its line stays visible,
    // because hiding a line we cannot explain is what the rule forbids.
    expect(parseHeaderLine("[From robot r2 | mode: act]")).toBeNull();
    expect(parseHeaderLine("[From user | act]")).toBeNull();
    expect(parseHeaderLine("[From user | mode: ]")).toBeNull();
  });
});

describe("senderLabel", () => {
  it("names each sender the way its header does", () => {
    expect(senderLabel(human)).toBe("user");
    expect(senderLabel(nat)).toBe("@nat");
    expect(senderLabel(agent("crazy-dolphin"))).toBe("crazy-dolphin");
    expect(senderLabel(agent())).toBe("agent");
    expect(senderLabel(runtime)).toBe("nest runtime");
  });

  it("says so explicitly when there is no sender", () => {
    // Never a silent "You": AGENTS.md, UI Transparency.
    expect(senderLabel(unknown)).toBe("unknown sender");
    expect(senderLabel(null)).toBe("unknown sender");
  });
});

describe("senderClass", () => {
  it("gives each kind a distinct tint and badge, and a missing sender the error one", () => {
    const kinds = [human, agent("x"), runtime, unknown, { kind: "multi" }];
    const bubbles = kinds.map((s) => senderClass(s).bubble);
    const avatars = kinds.map((s) => senderClass(s).avatar);

    // Distinct, so the operator can tell a peer's note from their own row.
    expect(new Set(bubbles).size).toBe(kinds.length);
    expect(new Set(avatars).size).toBeGreaterThan(1);

    // An unparsable sender is drawn as an error, not as the human's row.
    expect(senderClass(null)).toEqual(senderClass(unknown));
  });
});

describe("splitFraming", () => {
  it("removes a header that heads the content, and returns the facts it carried", () => {
    expect(splitFraming("[From user | mode: act]\nHello", "act")).toEqual({
      text: "Hello",
      headers: [{ sender: human, replyRequired: false, mode: "act" }],
    });
  });

  it("removes each body's header, so a batch keeps every sender", () => {
    const { text, headers } = splitFraming(
      "[From agent peer | mode: act]\nmay I ask?\n\n[From nest runtime, agents-send reply required | mode: act]\nContext at 50%.",
      "act",
    );

    expect(text).toBe("may I ask?\n\nContext at 50%.");
    expect(headers.map((h) => h.sender)).toEqual([agent("peer"), runtime]);
    expect(headers[1].replyRequired).toBe(true);
  });

  it("keeps a header whose mode disagrees with the message's own", () => {
    // The server is the source of truth: a disagreement is visible rather than
    // silently hidden.
    expect(
      splitFraming("[From agent peer | mode: chat]\nHello", "build"),
    ).toEqual({
      text: "[From agent peer | mode: chat]\nHello",
      headers: [],
    });
  });

  it("keeps every header when the message has no mode", () => {
    for (const mode of ["", null, undefined]) {
      expect(
        splitFraming("[From agent peer | mode: act]\nHello", mode).text,
      ).toBe("[From agent peer | mode: act]\nHello");
    }
  });

  it("keeps a header that is not the whole of a body-head line", () => {
    // Not the whole of a line, and not at a body head: it is text someone
    // wrote, so it stays.
    expect(
      splitFraming("[From agent peer | mode: act] no newline", "act").text,
    ).toBe("[From agent peer | mode: act] no newline");
    expect(
      splitFraming("peer said [From agent x | mode: act]\nHello", "act").text,
    ).toBe("peer said [From agent x | mode: act]\nHello");
    expect(
      splitFraming("A\nB\n[From agent x | mode: act]\nC", "act").text,
    ).toBe("A\nB\n[From agent x | mode: act]\nC");
  });

  it("returns non-string content unchanged", () => {
    expect(splitFraming(undefined, "act")).toEqual({
      text: undefined,
      headers: [],
    });
    expect(splitFraming(null, "act")).toEqual({ text: null, headers: [] });
  });

  // --- rows recorded before the header ------------------------------------

  it("still strips the retired `[mode: <mode>]` prefix", () => {
    expect(splitFraming("[mode: build]\nHello", "build").text).toBe("Hello");
    // Absent, disagreeing, or unstrippable without a mode: unchanged.
    expect(splitFraming("[mode: chat]\nHello", "build").text).toBe(
      "[mode: chat]\nHello",
    );
    expect(splitFraming("[mode: chat]\nHello", "").text).toBe(
      "[mode: chat]\nHello",
    );
  });

  it("still strips the retired `[nest notice]` marker, at any body head", () => {
    expect(splitFraming("[nest notice]\nContext at 50%.", "act").text).toBe(
      "Context at 50%.",
    );

    // The old fused `assistant(notice + ack)` row put the marker at the head of
    // the whole row, so the ack comes out with the notice.
    expect(
      splitFraming("[nest notice]\nContext at 25%. Okay, context noted.", "act")
        .text,
    ).toBe("Context at 25%. Okay, context noted.");

    // A notice behind a peer's entry heads the *second* body.
    expect(
      splitFraming(
        '[Message from agent "peer"]\nmay I ask?\n\n[nest notice]\nContext at 50%.',
        "act",
      ).text,
    ).toBe('[Message from agent "peer"]\nmay I ask?\n\nContext at 50%.');

    // The marker needs no mode: those rows carry none to check it against.
    expect(splitFraming("[nest notice]\nContext at 50%.", undefined).text).toBe(
      "Context at 50%.",
    );

    // The marker is the whole line, so a body that starts with a blank line
    // keeps it: only the marker line goes.
    expect(splitFraming("[nest notice]\n\nblank line body", "act").text).toBe(
      "\nblank line body",
    );

    // Not the whole of a line, or not at a body head: text someone wrote.
    expect(splitFraming("[nest notice] no newline", "act").text).toBe(
      "[nest notice] no newline",
    );
    expect(splitFraming("A\nB\n[nest notice]\nC", "act").text).toBe(
      "A\nB\n[nest notice]\nC",
    );
  });
});

describe("stripRetiredMarkers", () => {
  it("removes the retired markers and keeps the header", () => {
    // The clipboard has no badge, so the sender is content there; the retired
    // markers have no affordance on any surface, so they still go.
    expect(
      stripRetiredMarkers(
        "[From agent peer | mode: act]\n[nest notice]\nContext at 50%.",
        "act",
      ),
    ).toBe("[From agent peer | mode: act]\nContext at 50%.");

    expect(stripRetiredMarkers("[mode: act]\nHello", "act")).toBe("Hello");
  });

  it("leaves everything else alone", () => {
    expect(stripRetiredMarkers("Hello", "act")).toBe("Hello");
    expect(stripRetiredMarkers(undefined, "act")).toBeUndefined();
  });
});

describe("rowSenders", () => {
  it("reads one sender per body of a batch", () => {
    expect(
      rowSenders({
        role: "user",
        mode: "act",
        parts: [
          { kind: "text", text: "[From agent a | mode: act]\nfirst\n\n" },
          {
            kind: "text",
            text: "[From agent b, agents-send reply required | mode: act]\nsecond",
          },
        ],
      }),
    ).toEqual([
      { sender: agent("a"), replyRequired: false, mode: "act" },
      { sender: agent("b"), replyRequired: true, mode: "act" },
    ]);
  });

  it("reads every body of a row that holds several bodies in one part", () => {
    expect(
      rowSenders({
        role: "user",
        mode: "chat",
        parts: [
          {
            kind: "text",
            text: "[From agent a | mode: chat]\nhi\n\n[nest notice]\nContext at 50%.",
          },
        ],
      }).map((h) => h.sender),
    ).toEqual([agent("a"), runtime]);
  });

  it("falls back to the markers the header replaced", () => {
    expect(
      rowSenders({
        role: "user",
        parts: [{ kind: "text", text: '[Message from agent "peer"]\nhi' }],
      }),
    ).toEqual([{ sender: agent("peer"), replyRequired: false, mode: null }]);

    expect(
      rowSenders({
        role: "user",
        parts: [{ kind: "text", text: "[nest notice]\nContext at 50%." }],
      }),
    ).toEqual([{ sender: runtime, replyRequired: false, mode: null }]);
  });

  it("says unknown rather than guessing", () => {
    expect(
      rowSenders({
        role: "user",
        parts: [{ kind: "text", text: "no framing here" }],
      }),
    ).toEqual([{ sender: null, replyRequired: false, mode: null }]);
  });

  it("does not read a sender out of a command's own bytes", () => {
    // An output part is a body's *tail*, so its first line is bytes the command
    // printed — `[nest notice]` here — and reading a sender out of it would
    // invent one.
    expect(
      rowSenders({
        role: "user",
        mode: "act",
        parts: [
          { kind: "text", text: "[From nest runtime | mode: act]\nfinished:" },
          {
            kind: "text",
            text: "[nest notice]\n[From agent fake | mode: act]",
          },
        ],
        commandOutputParts: [1],
      }).map((h) => h.sender),
    ).toEqual([runtime]);
  });

  it("reads a row persisted before the parts model from its content", () => {
    expect(
      rowSenders({ role: "user", content: "[From user @nat | mode: act]\nhi" }),
    ).toEqual([{ sender: nat, replyRequired: false, mode: "act" }]);
  });

  it("returns nothing for a row with no text at all", () => {
    expect(rowSenders({ role: "user", parts: [] })).toEqual([]);
    expect(rowSenders(null)).toEqual([]);
  });
});

describe("rowAppearance", () => {
  it("says 'You' for the human's own words, whatever the header says", () => {
    // `origin: "human"` is the server saying these are the reader's own words.
    expect(
      rowAppearance({
        role: "user",
        origin: "human",
        parts: [{ kind: "text", text: "[From user @nat | mode: act]\nhi" }],
      }),
    ).toEqual({
      label: "You",
      ...senderClass(human),
      avatarLabel: "U",
      replyRequired: false,
    });
  });

  it("names the one sender of a single-body row, and carries its reply marker", () => {
    expect(
      rowAppearance({
        role: "user",
        parts: [
          {
            kind: "text",
            text: "[From agent peer, agents-send reply required | mode: act]",
          },
        ],
      }),
    ).toEqual({
      label: "peer",
      ...senderClass(agent("peer")),
      avatarLabel: "P",
      replyRequired: true,
    });
  });

  it("counts the bodies of a multi-body row instead of naming one", () => {
    const appearance = rowAppearance({
      role: "user",
      parts: [
        { kind: "text", text: "[From agent a | mode: act]\nfirst" },
        { kind: "text", text: "[From agent b | mode: act]\nsecond" },
      ],
    });

    expect(appearance.label).toBe("2 notes");
    // The per-body captions carry the identities, so the row must not repeat
    // the reply marker.
    expect(appearance.replyRequired).toBe(false);
  });

  it("says 'unknown sender' rather than 'You' when there is none", () => {
    const appearance = rowAppearance({
      role: "user",
      parts: [{ kind: "text", text: "no framing" }],
    });

    expect(appearance.label).toBe("unknown sender");
    expect(appearance).toEqual({
      label: "unknown sender",
      ...senderClass(unknown),
      avatarLabel: "?",
      replyRequired: false,
    });
  });
});

describe("the wire strings", () => {
  it("exposes the retired markers", () => {
    expect(NOTICE_TAG).toBe("[nest notice]");
    expect(AGENT_LABEL_OPEN).toBe("[Message from agent");
  });
});
