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
