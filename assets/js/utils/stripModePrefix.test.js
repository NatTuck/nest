import { describe, expect, it } from "vitest";
import { stripModePrefix } from "./stripModePrefix.js";

describe("stripModePrefix", () => {
  it("strips the prefix when content starts with `[mode: <mode>]\\n`", () => {
    expect(stripModePrefix("[mode: build]\nHello", "build")).toBe("Hello");
    expect(stripModePrefix("[mode: chat]\nWhat's up?", "chat")).toBe(
      "What's up?",
    );
    expect(stripModePrefix("[mode: plan]\nLine 1\nLine 2", "plan")).toBe(
      "Line 1\nLine 2",
    );
    // The runtime's compaction request is a committed `user` row, so it goes
    // through this same stripper. Its mode is not one the operator can select,
    // which is what made it easy to overlook: the row reached the transcript
    // with `[mode: compact]` intact until it carried a `mode` to match.
    expect(
      stripModePrefix(
        "[mode: compact]\nSummarize the conversation in your 4096 remaining tokens.",
        "compact",
      ),
    ).toBe("Summarize the conversation in your 4096 remaining tokens.");
  });

  it("returns the content unchanged when the prefix is absent", () => {
    expect(stripModePrefix("Hello", "build")).toBe("Hello");
    expect(stripModePrefix("[mode: chat]\nHello", "build")).toBe(
      "[mode: chat]\nHello",
    );
    expect(stripModePrefix("Some other text", "build")).toBe("Some other text");
  });

  it("does not strip when mode is empty or missing", () => {
    expect(stripModePrefix("[mode: chat]\nHello", "")).toBe(
      "[mode: chat]\nHello",
    );
    expect(stripModePrefix("[mode: chat]\nHello", null)).toBe(
      "[mode: chat]\nHello",
    );
    expect(stripModePrefix("[mode: chat]\nHello", undefined)).toBe(
      "[mode: chat]\nHello",
    );
  });

  it("does not strip when the prefix mode disagrees with the message mode", () => {
    // Server is the source of truth — if `mode` says "build" but the
    // content is prefixed with `[mode: chat]`, leave it alone rather
    // than silently strip a different mode.
    expect(stripModePrefix("[mode: chat]\nHello", "build")).toBe(
      "[mode: chat]\nHello",
    );
  });

  it("returns non-string content unchanged", () => {
    expect(stripModePrefix(undefined, "build")).toBeUndefined();
    expect(stripModePrefix(null, "build")).toBeNull();
    expect(stripModePrefix(42, "build")).toBe(42);
  });
});
