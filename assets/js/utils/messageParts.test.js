/**
 * Tests for `messageParts.js` — the helpers that derive
 * canonical `parts` shapes from wire-format messages and
 * back into the flat legacy fields some components still
 * read (thinking, toolCalls, toolResults, textParts).
 *
 * `toolCallsFromParts/1` passes `arguments` through unchanged
 * so the renderer (`formatToolCall` + `ToolCalls.jsx`) can
 * decide between streaming-monospace and final-JSON based
 * on whether the value is a partial buffer or a parsed
 * object. The legacy behavior of decoding partial JSON to
 * `{}` lost the streaming preview; we now keep the raw.
 */
import { describe, it, expect } from "vitest";

import {
  thinkingFor,
  textPartsFor,
  toolCallsFromParts,
  toolResultsFromParts,
  formatToolCall,
  LONG_FIELD_THRESHOLD,
} from "./messageParts.js";

describe("thinkingFor", () => {
  it("returns null for null/undefined messages", () => {
    expect(thinkingFor(null)).toBeNull();
    expect(thinkingFor(undefined)).toBeNull();
  });

  it("concatenates Part.Thinking entries with blank-line separators", () => {
    expect(
      thinkingFor({
        parts: [
          { kind: "thinking", thinking: "first" },
          { kind: "thinking", thinking: "second" },
        ],
      }),
    ).toBe("first\n\nsecond");
  });

  it("falls back to message.thinking when parts has no thinking entries", () => {
    expect(thinkingFor({ thinking: "legacy" })).toBe("legacy");
  });
});

describe("textPartsFor", () => {
  it("splits think tags out of Part.Text entries", () => {
    expect(
      textPartsFor({
        parts: [
          {
            kind: "text",
            text: "before<think>reasoning</think>after",
          },
        ],
      }),
    ).toEqual([
      { kind: "text", text: "before" },
      { kind: "text", text: "after" },
    ]);
  });
  it("preserves non-text/non-thinking parts (e.g. tool_use) for downstream renderers", () => {
    const toolUse = { kind: "tool_use", id: "x", name: "shell-cmd" };
    expect(textPartsFor({ parts: [toolUse] })).toEqual([toolUse]);
  });
});

describe("toolCallsFromParts", () => {
  it("returns null when parts is null or missing", () => {
    expect(toolCallsFromParts(null)).toBeNull();
    expect(toolCallsFromParts(undefined)).toBeNull();
  });

  it("returns null when no tool_use parts are present", () => {
    expect(
      toolCallsFromParts([{ kind: "text", text: "no tools here" }]),
    ).toBeNull();
  });

  it("returns the id/name of every tool_use part", () => {
    const result = toolCallsFromParts([
      { kind: "thinking", thinking: "..." },
      { kind: "tool_use", id: "a", name: "shell-cmd", arguments: {} },
      { kind: "text", text: "..." },
      { kind: "tool_use", id: "b", name: "file-read", arguments: {} },
    ]);
    expect(result).toHaveLength(2);
    expect(result[0].id).toBe("a");
    expect(result[0].name).toBe("shell-cmd");
    expect(result[1].id).toBe("b");
    expect(result[1].name).toBe("file-read");
  });

  it("passes through object `arguments` (the finalized / DB shape)", () => {
    const args = { command: "ls", path: "/tmp" };
    const result = toolCallsFromParts([
      { kind: "tool_use", id: "a", name: "shell-cmd", arguments: args },
    ]);
    expect(result[0].arguments).toBe(args);
  });

  it("passes through string `arguments` (the streaming shape) unchanged", () => {
    // The renderer (`formatToolCall`) decides how to display
    // the partial buffer. We keep the raw bytes here so the
    // streaming preview is never thrown away.
    const result = toolCallsFromParts([
      {
        kind: "tool_use",
        id: "a",
        name: "shell-cmd",
        arguments: '{"command":',
      },
    ]);
    expect(result[0].arguments).toBe('{"command":');
  });

  it("substitutes an empty string for missing/null `arguments`", () => {
    // The streaming model: `arguments` is always a string (or
    // absent → ""). Previously this returned `{}` which the
    // renderer treated as "no preview to show"; now we pass
    // through so `formatToolCall` can branch on emptiness.
    const result = toolCallsFromParts([
      { kind: "tool_use", id: "a", name: "shell-cmd" },
    ]);
    expect(result[0].arguments).toBe("");
  });
});

describe("formatToolCall", () => {
  it("returns kind:empty when arguments is missing or empty", () => {
    expect(formatToolCall(null)).toEqual({ kind: "empty" });
    expect(formatToolCall({ name: "x" })).toEqual({ kind: "empty" });
    expect(formatToolCall({ name: "x", arguments: "" })).toEqual({
      kind: "empty",
    });
  });

  it("returns kind:object for finalized (parsed) arguments", () => {
    const args = { command: "ls -la" };
    expect(formatToolCall({ name: "shell-cmd", arguments: args })).toEqual({
      kind: "object",
      value: args,
    });
  });

  it("returns kind:stream-short for partial JSON that doesn't parse yet", () => {
    // `{"command":` is partial — JSON.parse throws, so we land in
    // the monospace-raw branch.
    const formatted = formatToolCall({
      name: "shell-cmd",
      arguments: '{"command":',
    });
    expect(formatted.kind).toBe("stream-short");
    expect(formatted.raw).toBe('{"command":');
  });

  it("returns kind:object when the partial buffer parses to a small object", () => {
    // `{"command":"ls"}` parses cleanly — render the same
    // object-shape row as the finalized version.
    const formatted = formatToolCall({
      name: "shell-cmd",
      arguments: '{"command":"ls"}',
    });
    expect(formatted).toEqual({
      kind: "object",
      value: { command: "ls" },
    });
  });

  it("returns kind:stream-long when a single string field crosses the long-field threshold", () => {
    const longContent = "x".repeat(LONG_FIELD_THRESHOLD + 1);
    const formatted = formatToolCall({
      name: "file-write",
      arguments: JSON.stringify({
        path: "/tmp/foo.txt",
        content: longContent,
      }),
    });
    expect(formatted.kind).toBe("stream-long");
    expect(formatted.previewField).toBe("content");
    expect(formatted.preview).toBe(longContent);
  });

  it("returns kind:object when a short partial buffer parses to a small object", () => {
    // Below `LONG_TOTAL_THRESHOLD` total length and with a
    // parseable object shape, the small-object path renders
    // the formatted JSON preview. The buffer happens to be
    // mid-stream (the LLM might be still streaming more
    // fields), but at this size the preview reads cleanly
    // and the user can see what's flowing through.
    const args = JSON.stringify({
      command: "ls",
      metadata: "x".repeat(150),
    });
    const formatted = formatToolCall({
      name: "shell-cmd",
      arguments: args,
    });
    expect(formatted.kind).toBe("object");
    expect(formatted.value).toEqual({
      command: "ls",
      metadata: "x".repeat(150),
    });
  });

  it("picks the longest string field when multiple cross the threshold", () => {
    const formatted = formatToolCall({
      name: "file-write",
      arguments: JSON.stringify({
        content1: "a".repeat(LONG_FIELD_THRESHOLD + 10),
        content2: "b".repeat(LONG_FIELD_THRESHOLD + 200),
      }),
    });
    expect(formatted.previewField).toBe("content2");
  });
});

describe("toolResultsFromParts", () => {
  it("returns null when parts is null or missing", () => {
    expect(toolResultsFromParts(null)).toBeNull();
    expect(toolResultsFromParts(undefined)).toBeNull();
  });

  it("returns null when no tool_result parts are present", () => {
    expect(toolResultsFromParts([{ kind: "text", text: "x" }])).toBeNull();
  });

  it("derives the legacy tool_result shape from tool_result parts", () => {
    const result = toolResultsFromParts([
      {
        kind: "tool_result",
        toolCallId: "call_1",
        name: "shell-cmd",
        content: "ok",
        isError: false,
      },
    ]);
    expect(result).toEqual([
      {
        tool_call_id: "call_1",
        name: "shell-cmd",
        content: "ok",
        is_error: false,
      },
    ]);
  });
});
