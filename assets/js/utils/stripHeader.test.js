import { describe, expect, it } from "vitest";
import { NOTICE_TAG, stripHeader } from "./stripHeader.js";

describe("stripHeader", () => {
  it("strips the header when it heads the content", () => {
    expect(stripHeader("[From user | mode: act]\nHello", "act")).toBe("Hello");

    expect(stripHeader("[From agent peer | mode: plan]\nhi there", "plan")).toBe(
      "hi there",
    );

    expect(
      stripHeader("[From nest runtime | mode: act]\nContext at 50%.", "act"),
    ).toBe("Context at 50%.");

    // A note that obliges an answer states it in the same header.
    expect(
      stripHeader(
        "[From agent peer, agents-send reply required | mode: act]\nmay I ask?",
        "act",
      ),
    ).toBe("may I ask?");

    // The compaction request is a committed `user` row, so it goes through this
    // same stripper. Its mode is not one the operator can select, which is what
    // made it easy to overlook.
    expect(
      stripHeader(
        "[From nest runtime | mode: compact]\nSummarize the conversation in your 4096 remaining tokens.",
        "compact",
      ),
    ).toBe("Summarize the conversation in your 4096 remaining tokens.");

    expect(
      stripHeader("[From user | mode: plan]\nLine 1\nLine 2", "plan"),
    ).toBe("Line 1\nLine 2");

    expect(stripHeader("[From user | mode: act]\n\nblank line body", "act")).toBe(
      "\nblank line body",
    );
  });

  it("strips each body's header, so a batch keeps every sender", () => {
    // A drain batch is one row holding several entries, and each entry's body
    // carries its own header: a single leading-prefix removal would leave the
    // rest on screen.
    expect(
      stripHeader(
        "[From agent peer | mode: act]\nmay I ask?\n\n[From nest runtime | mode: act]\nContext at 50%.",
        "act",
      ),
    ).toBe("may I ask?\n\nContext at 50%.");

    // Two bodies of the same kind: both heads go.
    expect(
      stripHeader(
        "[From user | mode: act]\nA\n\n[From agent peer | mode: act]\nB",
        "act",
      ),
    ).toBe("A\n\nB");
  });

  it("keeps the blank lines inside a body", () => {
    expect(
      stripHeader(
        "[From nest runtime | mode: act]\nYour backgrounded command (x) finished. Its result:\n\nthe output",
        "act",
      ),
    ).toBe("Your backgrounded command (x) finished. Its result:\n\nthe output");

    expect(stripHeader("[From user | mode: act]\n\nA\n\nB", "act")).toBe(
      "\nA\n\nB",
    );
  });

  it("does not strip when the header's mode disagrees with the message mode", () => {
    // The server is the source of truth: a disagreement is visible rather than
    // silently hidden.
    expect(stripHeader("[From agent peer | mode: chat]\nHello", "build")).toBe(
      "[From agent peer | mode: chat]\nHello",
    );
  });

  it("does not strip a header when the message has no mode", () => {
    expect(stripHeader("[From agent peer | mode: act]\nHello", "")).toBe(
      "[From agent peer | mode: act]\nHello",
    );
    expect(stripHeader("[From agent peer | mode: act]\nHello", null)).toBe(
      "[From agent peer | mode: act]\nHello",
    );
    expect(stripHeader("[From agent peer | mode: act]\nHello", undefined)).toBe(
      "[From agent peer | mode: act]\nHello",
    );
  });

  it("does not strip a header that is not the whole of a body-head line", () => {
    // Not the whole of a line, and not at a body head: it is text someone
    // wrote, so it stays.
    expect(stripHeader("[From agent peer | mode: act] no newline", "act")).toBe(
      "[From agent peer | mode: act] no newline",
    );
    expect(stripHeader("peer said [From agent x | mode: act]\nHello", "act")).toBe(
      "peer said [From agent x | mode: act]\nHello",
    );
    expect(stripHeader("A\nB\n[From agent x | mode: act]\nC", "act")).toBe(
      "A\nB\n[From agent x | mode: act]\nC",
    );
  });

  it("returns the content unchanged when there is no header", () => {
    expect(stripHeader("Hello", "build")).toBe("Hello");
    expect(stripHeader("Some other text", "build")).toBe("Some other text");
  });

  it("returns non-string content unchanged", () => {
    expect(stripHeader(undefined, "build")).toBeUndefined();
    expect(stripHeader(null, "build")).toBeNull();
    expect(stripHeader(42, "build")).toBe(42);
  });

  // --- rows recorded before the header -----------------------------------
  //
  // The markers the header replaced are still in every transcript written
  // before this change. Dropping this support would leave old conversations
  // showing wire framing in the UI.

  it("still strips the retired `[mode: <mode>]` prefix", () => {
    expect(stripHeader("[mode: build]\nHello", "build")).toBe("Hello");
    expect(stripHeader("[mode: chat]\nWhat's up?", "chat")).toBe("What's up?");
    expect(stripHeader("[mode: plan]\nLine 1\nLine 2", "plan")).toBe(
      "Line 1\nLine 2",
    );
    expect(
      stripHeader(
        "[mode: compact]\nSummarize the conversation in your 4096 remaining tokens.",
        "compact",
      ),
    ).toBe("Summarize the conversation in your 4096 remaining tokens.");

    // Absent, disagreeing, or unstrippable without a mode: unchanged.
    expect(stripHeader("Hello", "build")).toBe("Hello");
    expect(stripHeader("[mode: chat]\nHello", "build")).toBe(
      "[mode: chat]\nHello",
    );
    expect(stripHeader("[mode: chat]\nHello", "")).toBe("[mode: chat]\nHello");
    expect(stripHeader("[mode: chat]\nHello", null)).toBe("[mode: chat]\nHello");
    expect(stripHeader("[mode: chat]\nHello", undefined)).toBe(
      "[mode: chat]\nHello",
    );
  });

  it("still strips the retired `[nest notice]` marker, at any body head", () => {
    expect(stripHeader("[nest notice]\nContext at 50%.", "act")).toBe(
      "Context at 50%.",
    );

    // The old fused `assistant(notice + ack)` row put the marker at the head of
    // the whole row, so the ack comes out with the notice.
    expect(
      stripHeader("[nest notice]\nContext at 25%. Okay, context noted.", "act"),
    ).toBe("Context at 25%. Okay, context noted.");

    // A notice behind a peer's entry heads the *second* body.
    expect(
      stripHeader(
        '[Message from agent "peer"]\nmay I ask?\n\n[nest notice]\nContext at 50%.',
        "act",
      ),
    ).toBe('[Message from agent "peer"]\nmay I ask?\n\nContext at 50%.');

    expect(stripHeader("[nest notice]\nA\n\n[nest notice]\nB", "act")).toBe(
      "A\n\nB",
    );

    // The marker needs no mode: those rows carry none to check it against.
    expect(stripHeader("[nest notice]\nContext at 50%.", undefined)).toBe(
      "Context at 50%.",
    );

    // Not the whole of a line, or not at a body head: text someone wrote.
    expect(stripHeader("[nest notice] no newline", "act")).toBe(
      "[nest notice] no newline",
    );
    expect(stripHeader("peer said [nest notice]\nHello", "act")).toBe(
      "peer said [nest notice]\nHello",
    );
    expect(stripHeader("A\nB\n[nest notice]\nC", "act")).toBe(
      "A\nB\n[nest notice]\nC",
    );
  });

  it("exposes the retired marker string itself", () => {
    expect(NOTICE_TAG).toBe("[nest notice]");
  });
});
