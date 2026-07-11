import { describe, expect, it } from "vitest";
import { splitThinkTags, splitThinkFromParts } from "./thinkTags.js";

describe("splitThinkTags", () => {
  it("returns no segments for empty / non-string input", () => {
    expect(splitThinkTags("")).toEqual([]);
    expect(splitThinkTags(null)).toEqual([]);
    expect(splitThinkTags(undefined)).toEqual([]);
    expect(splitThinkTags(42)).toEqual([]);
  });

  it("returns a single text segment when there are no markers", () => {
    expect(splitThinkTags("hello world")).toEqual([
      { kind: "text", text: "hello world" },
    ]);
  });

  it("splits a single <think>...</think> block", () => {
    expect(splitThinkTags("before<think>reasoning</think>after")).toEqual([
      { kind: "text", text: "before" },
      { kind: "thinking", text: "reasoning" },
      { kind: "text", text: "after" },
    ]);
  });

  it("splits multiple blocks in the same string", () => {
    expect(splitThinkTags("a<think>1</think>b<think>2</think>c")).toEqual([
      { kind: "text", text: "a" },
      { kind: "thinking", text: "1" },
      { kind: "text", text: "b" },
      { kind: "thinking", text: "2" },
      { kind: "text", text: "c" },
    ]);
  });

  it("handles an empty think block (<think></think>)", () => {
    expect(splitThinkTags("before<think></think>after")).toEqual([
      { kind: "text", text: "before" },
      { kind: "thinking", text: "" },
      { kind: "text", text: "after" },
    ]);
  });

  it("handles an orphan closing </think> (no matching <think>)", () => {
    // Stray `</think>` in the response is treated as a thinking
    // marker — the orphan text and everything after is routed
    // to the thinking channel. The orphan itself is consumed
    // (so the user doesn't see raw `</think>` characters).
    expect(splitThinkTags("before</think>after")).toEqual([
      { kind: "text", text: "before" },
      { kind: "thinking", text: "after" },
    ]);
  });

  it("handles an orphan <think> (no matching </think>)", () => {
    // The open `<think>` is consumed and everything from there
    // to the end of the string is routed to the thinking
    // channel (an incomplete think block).
    expect(splitThinkTags("before<think>reasoning")).toEqual([
      { kind: "text", text: "before" },
      { kind: "thinking", text: "reasoning" },
    ]);
  });

  it("does not recurse into a nested <think> inside a think block", () => {
    // The inner `<think>` is just text inside the outer think
    // block — we don't open a new thinking segment.
    expect(
      splitThinkTags("a<think>outer<think>inner</think>end</think>b"),
    ).toEqual([
      { kind: "text", text: "a" },
      { kind: "thinking", text: "outer<think>inner</think>end" },
      { kind: "text", text: "b" },
    ]);
  });

  it("preserves whitespace and newlines in segments", () => {
    expect(
      splitThinkTags("line1\n<think>\nreasoning\n\nmore\n</think>\nline2\n"),
    ).toEqual([
      { kind: "text", text: "line1\n" },
      { kind: "thinking", text: "\nreasoning\n\nmore\n" },
      { kind: "text", text: "\nline2\n" },
    ]);
  });

  it("treats </think>\\n\\n as thinking (orphan closing)", () => {
    // The exact stray-text pattern from the regression:
    // </think>\n\n leaking into the assistant's reply.
    expect(splitThinkTags("hello</think>\n\nworld")).toEqual([
      { kind: "text", text: "hello" },
      { kind: "thinking", text: "\n\nworld" },
    ]);
  });
});

describe("splitThinkFromParts", () => {
  it("returns null/empty for non-array input", () => {
    expect(splitThinkFromParts(null)).toEqual({
      thinking: null,
      textParts: [],
    });
    expect(splitThinkFromParts(undefined)).toEqual({
      thinking: null,
      textParts: [],
    });
  });

  it("returns the parts unchanged when no think markers are present", () => {
    const parts = [
      { kind: "thinking", thinking: "reasoning" },
      { kind: "text", text: "hello" },
    ];
    expect(splitThinkFromParts(parts)).toEqual({
      thinking: "reasoning",
      textParts: [{ kind: "text", text: "hello" }],
    });
  });

  it("concatenates multiple Part.Thinking entries with a blank-line separator", () => {
    const parts = [
      { kind: "thinking", thinking: "first" },
      { kind: "thinking", thinking: "second" },
    ];
    expect(splitThinkFromParts(parts)).toEqual({
      thinking: "first\n\nsecond",
      textParts: [],
    });
  });

  it("splits a <think> block inside a Part.Text", () => {
    const parts = [
      { kind: "text", text: "before<think>reasoning</think>after" },
    ];
    const result = splitThinkFromParts(parts);
    expect(result.thinking).toBe("reasoning");
    expect(result.textParts).toEqual([
      { kind: "text", text: "before" },
      { kind: "text", text: "after" },
    ]);
  });

  it("combines a Part.Thinking and a <think> in Part.Text", () => {
    const parts = [
      { kind: "thinking", thinking: "alpha" },
      { kind: "text", text: "before<think>beta</think>after" },
    ];
    const result = splitThinkFromParts(parts);
    expect(result.thinking).toBe("alpha\n\nbeta");
    expect(result.textParts).toEqual([
      { kind: "text", text: "before" },
      { kind: "text", text: "after" },
    ]);
  });

  it("preserves non-text/non-thinking parts unchanged", () => {
    const toolUse = { kind: "tool_use", id: "1", name: "x", arguments: {} };
    const toolResult = {
      kind: "tool_result",
      toolCallId: "1",
      content: "ok",
    };
    const parts = [
      { kind: "text", text: "before" },
      toolUse,
      { kind: "text", text: "<think>r</think>after" },
      toolResult,
    ];
    const result = splitThinkFromParts(parts);
    expect(result.thinking).toBe("r");
    expect(result.textParts).toEqual([
      { kind: "text", text: "before" },
      toolUse,
      { kind: "text", text: "after" },
      toolResult,
    ]);
  });

  it("returns null thinking when no think content is present", () => {
    const parts = [
      { kind: "text", text: "hello" },
      { kind: "text", text: "world" },
    ];
    const result = splitThinkFromParts(parts);
    expect(result.thinking).toBeNull();
    expect(result.textParts).toEqual([
      { kind: "text", text: "hello" },
      { kind: "text", text: "world" },
    ]);
  });

  it("skips null/undefined entries in the parts array", () => {
    const parts = [
      null,
      { kind: "text", text: "before<think>r</think>after" },
      undefined,
    ];
    const result = splitThinkFromParts(parts);
    expect(result.thinking).toBe("r");
    expect(result.textParts).toEqual([
      { kind: "text", text: "before" },
      { kind: "text", text: "after" },
    ]);
  });
});
