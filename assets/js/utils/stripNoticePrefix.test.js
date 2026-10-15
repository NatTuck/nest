import { describe, expect, it } from "vitest";
import { NOTICE_TAG, stripNoticePrefix } from "./stripNoticePrefix.js";

// The re-delivery line `Inbox.Render` puts in front of a body a caller already
// fetched (issue #62).
const REDELIVERY =
  "[re-delivery: this body was already retrieved with agents-last-message]";

describe("stripNoticePrefix", () => {
  it("strips the marker when it heads the content", () => {
    expect(stripNoticePrefix("[nest notice]\nContext at 50%.")).toBe(
      "Context at 50%.",
    );
    expect(
      stripNoticePrefix(
        "[nest notice]\nContext at 75%. Do not stop due to context concerns, continue working through compaction.",
      ),
    ).toBe(
      "Context at 75%. Do not stop due to context concerns, continue working through compaction.",
    );
    // The fused `assistant(notice + ack)` row puts the marker at the head of
    // the whole row, so the ack comes out with the notice.
    expect(
      stripNoticePrefix("[nest notice]\nContext at 25%. Okay, context noted."),
    ).toBe("Context at 25%. Okay, context noted.");
    expect(stripNoticePrefix("[nest notice]\n\nblank line body")).toBe(
      "\nblank line body",
    );
  });

  it("strips the marker at the head of a later body, not just the content", () => {
    // A drain batch is its entries joined by a blank line, so a notice behind
    // a peer's entry heads the *second* body. A single leading-prefix removal
    // would leave the marker on screen.
    expect(
      stripNoticePrefix(
        '[Message from agent "peer"]\nmay I ask?\n\n[nest notice]\nContext at 50%.',
      ),
    ).toBe('[Message from agent "peer"]\nmay I ask?\n\nContext at 50%.');

    // Two notices in one batch: both heads go.
    expect(stripNoticePrefix("[nest notice]\nA\n\n[nest notice]\nB")).toBe(
      "A\n\nB",
    );
  });

  it("strips the marker after the re-delivery line", () => {
    expect(
      stripNoticePrefix(`${REDELIVERY}\n[nest notice]\nContext at 50%.`),
    ).toBe(`${REDELIVERY}\nContext at 50%.`);
    expect(
      stripNoticePrefix(
        `[Message from agent "peer"]\nhi\n\n${REDELIVERY}\n[nest notice]\nContext at 50%.`,
      ),
    ).toBe(`[Message from agent "peer"]\nhi\n\n${REDELIVERY}\nContext at 50%.`);
  });

  it("keeps the blank lines inside a notice's own content", () => {
    // A backgrounded command's result is multi-paragraph: only the marker line
    // goes, and the body's own blank line survives.
    expect(
      stripNoticePrefix(
        "[nest notice]\nYour backgrounded command (x) finished. Its result:\n\nthe output",
      ),
    ).toBe("Your backgrounded command (x) finished. Its result:\n\nthe output");

    expect(stripNoticePrefix("[nest notice]\n\nA\n\nB")).toBe("\nA\n\nB");
  });

  it("returns the content unchanged when the marker is absent or not a body head", () => {
    expect(stripNoticePrefix("Hello")).toBe("Hello");
    expect(stripNoticePrefix("[nest notice] no newline")).toBe(
      "[nest notice] no newline",
    );
    // Not the whole of a line, and not at a body head: it is text someone
    // wrote, so it stays.
    expect(stripNoticePrefix("peer said [nest notice]\nHello")).toBe(
      "peer said [nest notice]\nHello",
    );
    expect(stripNoticePrefix("A\nB\n[nest notice]\nC")).toBe(
      "A\nB\n[nest notice]\nC",
    );
  });

  it("returns non-string content unchanged", () => {
    expect(stripNoticePrefix(undefined)).toBeUndefined();
    expect(stripNoticePrefix(null)).toBeNull();
    expect(stripNoticePrefix(42)).toBe(42);
  });

  it("exposes the marker string itself", () => {
    expect(NOTICE_TAG).toBe("[nest notice]");
  });
});
