import { describe, it, expect } from "vitest";
import { messageToMarkdown, formatApiLogsAsJson } from "./formatMessage.js";

describe("messageToMarkdown", () => {
  it("returns the user content with the [mode: X]\\n prefix stripped", () => {
    expect(
      messageToMarkdown({
        role: "user",
        content: "[mode: build]\nHello",
        mode: "build",
      }),
    ).toBe("Hello");
    expect(
      messageToMarkdown({
        role: "user",
        content: "[mode: chat]\nWhat's up?",
        mode: "chat",
      }),
    ).toBe("What's up?");
  });

  it("returns the user content as-is when the mode prefix disagrees with the message mode", () => {
    // Server is the source of truth — leave the prefix alone if
    // it doesn't match the explicit `mode` field. See
    // `stripModePrefix` for the rationale.
    expect(
      messageToMarkdown({
        role: "user",
        content: "[mode: chat]\nHello",
        mode: "build",
      }),
    ).toBe("[mode: chat]\nHello");
  });

  it("returns the user content as-is when no mode field is present", () => {
    expect(messageToMarkdown({ role: "user", content: "Hello" })).toBe("Hello");
  });

  it("returns the assistant content with thinking prepended and separated by a horizontal rule", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "Let me think about this.",
        content: "Here is the answer.",
      }),
    ).toBe("Let me think about this.\n\n---\n\nHere is the answer.");
  });

  it("returns just the thinking when assistant content is empty", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "reasoning only",
        content: "",
      }),
    ).toBe("reasoning only");
  });

  it("returns just the content when assistant thinking is empty", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "",
        content: "the answer",
      }),
    ).toBe("the answer");
  });

  it("returns the content verbatim for system and tool roles", () => {
    expect(
      messageToMarkdown({
        role: "system",
        content: "You are a helpful agent.",
      }),
    ).toBe("You are a helpful agent.");
    expect(
      messageToMarkdown({
        role: "tool",
        content: "File written successfully.",
      }),
    ).toBe("File written successfully.");
  });

  it("returns an empty string for missing/empty content with no thinking fallback", () => {
    expect(messageToMarkdown(null)).toBe("");
    expect(messageToMarkdown(undefined)).toBe("");
    expect(messageToMarkdown({ role: "user" })).toBe("");
    expect(messageToMarkdown({ role: "user", content: "" })).toBe("");
  });

  it("returns content as-is for unknown roles", () => {
    expect(messageToMarkdown({ role: "compaction", content: "..." })).toBe(
      "...",
    );
  });
});

describe("formatApiLogsAsJson", () => {
  it("returns an empty string for null or empty input", () => {
    expect(formatApiLogsAsJson(null)).toBe("");
    expect(formatApiLogsAsJson(undefined)).toBe("");
    expect(formatApiLogsAsJson([])).toBe("");
  });

  it("JSON-stringifies each payload with 2-space indentation", () => {
    const apiLogs = [
      { id: "log_1", timestamp: "t", type: "request", payload: { a: 1 } },
      { id: "log_2", timestamp: "t", type: "response", payload: { b: 2 } },
    ];
    const out = formatApiLogsAsJson(apiLogs);
    expect(out).toContain('"a": 1');
    expect(out).toContain('"b": 2');
    // The format mirrors JSON.stringify(payload, null, 2):
    // indented keys, not compact.
    expect(out).toContain('{\n  "a": 1\n}');
    expect(out).toContain('{\n  "b": 2\n}');
  });

  it("separates multiple log entries with a blank line", () => {
    const out = formatApiLogsAsJson([
      { id: "a", timestamp: "t", type: "request", payload: { a: 1 } },
      { id: "b", timestamp: "t", type: "response", payload: { b: 2 } },
    ]);
    expect(out).toMatch(/{\s*"a": 1\s*}\n\n{\s*"b": 2\s*}/);
  });

  it("handles a missing payload by stringifying null", () => {
    const out = formatApiLogsAsJson([{ id: "a", timestamp: "t", type: "x" }]);
    expect(out).toBe("null");
  });
});
