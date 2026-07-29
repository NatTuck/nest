/**
 * Tests for `messageParts.js` — the helpers that derive
 * canonical `parts` shapes from wire-format messages and
 * back into the flat legacy fields some components still
 * read (thinking, toolCalls, toolResults, textParts).
 *
 * `toolCallsFromParts/1` deserves specific coverage because
 * it JSON-decodes the `arguments` string assembled by the
 * streaming accumulator (a tool_use part's `arguments`
 * arrives as a string buffer of concatenated
 * `arguments_delta` fragments). The finalized shape has
 * `arguments` already as an object; both shapes need to
 * round-trip into the structured form `ToolCalls` expects.
 */
import { describe, it, expect } from "vitest";

import {
  thinkingFor,
  textPartsFor,
  toolCallsFromParts,
  toolResultsFromParts,
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
  it("splits <think> tags out of Part.Text entries", () => {
    expect(
      textPartsFor({
        parts: [{ kind: "text", text: "before<think>reasoning</think>after" }],
      }),
    ).toEqual([
      { kind: "text", text: "before" },
      { kind: "text", text: "after" },
    ]);
  });

  it("preserves non-text/non-thinking parts (e.g. tool_use) for downstream renderers", () => {
    const toolUse = { kind: "tool_use", id: "x", name: "shell_cmd" };
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
      { kind: "tool_use", id: "a", name: "shell_cmd", arguments: {} },
      { kind: "text", text: "..." },
      { kind: "tool_use", id: "b", name: "read_file", arguments: {} },
    ]);
    expect(result).toHaveLength(2);
    expect(result[0].id).toBe("a");
    expect(result[0].name).toBe("shell_cmd");
    expect(result[1].id).toBe("b");
    expect(result[1].name).toBe("read_file");
  });

  it("passes through object `arguments` (the finalized / DB shape)", () => {
    const args = { command: "ls", path: "/tmp" };
    const result = toolCallsFromParts([
      { kind: "tool_use", id: "a", name: "shell_cmd", arguments: args },
    ]);
    expect(result[0].arguments).toBe(args);
  });

  it("JSON-decodes string `arguments` (the streaming shape)", () => {
    const result = toolCallsFromParts([
      {
        kind: "tool_use",
        id: "a",
        name: "shell_cmd",
        arguments: '{"command":"ls"}',
      },
    ]);
    expect(result[0].arguments).toEqual({ command: "ls" });
  });

  it("decodes empty string `arguments` to an empty object", () => {
    const result = toolCallsFromParts([
      { kind: "tool_use", id: "a", name: "shell_cmd", arguments: "" },
    ]);
    expect(result[0].arguments).toEqual({});
  });

  it("falls back to an empty object when the JSON is malformed", () => {
    const result = toolCallsFromParts([
      {
        kind: "tool_use",
        id: "a",
        name: "shell_cmd",
        arguments: "{not valid json",
      },
    ]);
    expect(result[0].arguments).toEqual({});
  });

  it("falls back to an empty object when the JSON is a non-object primitive", () => {
    const result = toolCallsFromParts([
      {
        kind: "tool_use",
        id: "a",
        name: "shell_cmd",
        arguments: "42",
      },
    ]);
    expect(result[0].arguments).toEqual({});
  });

  it("falls back to an empty object when `arguments` is missing/null", () => {
    const result = toolCallsFromParts([
      { kind: "tool_use", id: "a", name: "shell_cmd" },
    ]);
    expect(result[0].arguments).toEqual({});
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
        name: "shell_cmd",
        content: "ok",
        isError: false,
      },
    ]);
    expect(result).toEqual([
      {
        tool_call_id: "call_1",
        name: "shell_cmd",
        content: "ok",
        is_error: false,
      },
    ]);
  });
});
