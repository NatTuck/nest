import { describe, expect, it } from "vitest";
import { NOTICE_TAG, stripNoticePrefix } from "./stripNoticePrefix.js";

describe("stripNoticePrefix", () => {
  it("strips the marker when content starts with `[nest notice]\\n`", () => {
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

  it("returns the content unchanged when the marker is absent", () => {
    expect(stripNoticePrefix("Hello")).toBe("Hello");
    expect(stripNoticePrefix("[nest notice] no newline")).toBe(
      "[nest notice] no newline",
    );
    // Not at the head: the strip is a leading-prefix removal, nothing more.
    expect(stripNoticePrefix("peer said [nest notice]\nHello")).toBe(
      "peer said [nest notice]\nHello",
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
