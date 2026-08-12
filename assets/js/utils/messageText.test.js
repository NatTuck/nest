/**
 * Tests for the canonical text-extraction helpers in messageText.js.
 *
 * Covers the branchy `messageText`/`streamingText` fallbacks and the
 * parts/text extractors. These functions are small but heavily
 * branched (nil checks, parts-vs-content fallback, thinking filters),
 * so they're unit-tested directly here.
 */
import { describe, it, expect } from "vitest";
import {
  textFromParts,
  thinkingFromParts,
  messageText,
  streamingText,
} from "./messageText";

describe("textFromParts", () => {
  it("returns empty string for a non-array", () => {
    expect(textFromParts(null)).toBe("");
    expect(textFromParts("nope")).toBe("");
  });

  it("concatenates only text parts, ignoring others", () => {
    expect(
      textFromParts([
        { kind: "text", text: "hello " },
        { kind: "thinking", thinking: "skip" },
        { kind: "text", text: "world" },
        { kind: "tool_call" },
      ]),
    ).toBe("hello world");
  });

  it("treats a missing text field as an empty string", () => {
    expect(
      textFromParts([{ kind: "text" }, { kind: "text", text: "hi" }]),
    ).toBe("hi");
  });
});

describe("thinkingFromParts", () => {
  it("returns empty string for a non-array", () => {
    expect(thinkingFromParts(null)).toBe("");
  });

  it("concatenates only thinking parts", () => {
    expect(
      thinkingFromParts([
        { kind: "thinking", thinking: "a" },
        { kind: "text", text: "b" },
        { kind: "thinking", thinking: "c" },
      ]),
    ).toBe("ac");
  });
});

describe("messageText", () => {
  it("returns empty string for a falsy message", () => {
    expect(messageText(null)).toBe("");
  });

  it("prefers a non-empty parts extraction", () => {
    expect(messageText({ parts: [{ kind: "text", text: "from parts" }] })).toBe(
      "from parts",
    );
  });

  it("falls back to content when parts produce no text", () => {
    expect(
      messageText({
        parts: [{ kind: "thinking", thinking: "x" }],
        content: "c",
      }),
    ).toBe("c");
  });

  it("falls back to a string content when there are no parts", () => {
    expect(messageText({ content: "plain" })).toBe("plain");
  });

  it("returns empty string when neither parts nor string content is present", () => {
    expect(messageText({ content: 42 })).toBe("");
    expect(messageText({})).toBe("");
  });
});

describe("streamingText", () => {
  it("returns empty string for a falsy accumulator", () => {
    expect(streamingText(null)).toBe("");
  });

  it("prefers a non-empty parts extraction", () => {
    expect(
      streamingText({ parts: [{ kind: "text", text: "in flight" }] }),
    ).toBe("in flight");
  });

  it("falls back to content when parts produce no text", () => {
    expect(
      streamingText({
        parts: [{ kind: "tool_call" }],
        content: "legacy",
      }),
    ).toBe("legacy");
  });

  it("falls back to a string content when there are no parts", () => {
    expect(streamingText({ content: "legacy content" })).toBe("legacy content");
  });

  it("returns empty string when neither parts nor string content is present", () => {
    expect(streamingText({ content: 99 })).toBe("");
  });
});
