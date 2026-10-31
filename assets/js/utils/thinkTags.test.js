/**
 * Tests for `leadingThinkBlock` — the one `<think>` rule the display still
 * applies.
 *
 * A marker is wire framing only when the fact it carries has a home elsewhere
 * in the row, and the only home left is a **leading matched** block on an
 * assistant row (the server writes at most one `Part.Thinking`, first). So the
 * function must look at the head of the string and nowhere else: a `<think>` in
 * the middle of prose is prose, and that is the regression these tests pin — an
 * assistant message reading "see `<think>` for details" must come through
 * untouched.
 */
import { describe, expect, it } from "vitest";
import { leadingThinkBlock } from "./thinkTags.js";

describe("leadingThinkBlock", () => {
  it("splits a leading matched block into its content and the rest", () => {
    expect(leadingThinkBlock("<think>reasoning</think>Answer.")).toEqual({
      thinking: "reasoning",
      rest: "Answer.",
    });
  });

  it("returns the remainder after the first closer, keeping it verbatim", () => {
    // Newlines and whitespace after the block are the body's, not the block's.
    expect(leadingThinkBlock("<think>\nwhy\n</think>\n\nAnswer\n")).toEqual({
      thinking: "\nwhy\n",
      rest: "\n\nAnswer\n",
    });
  });

  it("returns an empty rest for a block that is the whole string", () => {
    expect(leadingThinkBlock("<think>only reasoning</think>")).toEqual({
      thinking: "only reasoning",
      rest: "",
    });
  });

  it("returns an empty thinking string for an empty block", () => {
    // `<think></think>after` carries no reasoning; the caller decides that an
    // empty block is "no thinking" rather than inventing an empty box.
    expect(leadingThinkBlock("<think></think>after")).toEqual({
      thinking: "",
      rest: "after",
    });
  });

  it("ends at the first closer (nesting is not supported)", () => {
    expect(
      leadingThinkBlock("<think>outer<think>inner</think>rest</think>tail"),
    ).toEqual({ thinking: "outer<think>inner", rest: "rest</think>tail" });
  });

  it("returns null for a leading <think> with no closer", () => {
    expect(leadingThinkBlock("<think>reasoning")).toBeNull();
    expect(leadingThinkBlock("<think>")).toBeNull();
  });

  it("returns null for a <think> in the middle of prose", () => {
    // The exact regression: the old splitter treated this as an opener and
    // routed the rest of the message into the thinking channel, so the text
    // was truncated mid-sentence.
    expect(leadingThinkBlock("see <think> for details")).toBeNull();
    expect(leadingThinkBlock("before<think>reasoning</think>after")).toBeNull();
  });

  it("returns null for a closer with no opener", () => {
    expect(leadingThinkBlock("</think>after")).toBeNull();
    expect(leadingThinkBlock("hello</think>\n\nworld")).toBeNull();
  });

  it("returns null for text with no markers at all", () => {
    expect(leadingThinkBlock("hello world")).toBeNull();
    expect(leadingThinkBlock("")).toBeNull();
  });

  it("returns null for a non-string", () => {
    expect(leadingThinkBlock(null)).toBeNull();
    expect(leadingThinkBlock(undefined)).toBeNull();
    expect(leadingThinkBlock(42)).toBeNull();
  });
});
