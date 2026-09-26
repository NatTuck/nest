/**
 * Tests for `js/utils/chatHistory.js`.
 *
 * The helper powers the Ctrl/Cmd+Up chat-input history: it pulls user
 * messages from both the active session and the archived (post-compaction)
 * history, strips the `[mode: X]\n` prefix, orders them most-recent-first,
 * and collapses consecutive duplicates.
 */

import { describe, expect, it } from "vitest";
import { buildChatHistory } from "./chatHistory.js";

describe("buildChatHistory", () => {
  it("merges archived and active user messages most-recent-first, stripping the mode prefix", () => {
    const result = buildChatHistory(
      [
        { role: "user", content: "[mode: build]\nsecond", mode: "build" },
        { role: "assistant", content: "not a user message" },
      ],
      [{ role: "user", content: "[mode: plan]\nfirst", mode: "plan" }],
    );

    expect(result).toEqual([
      { content: "second", mode: "build" },
      { content: "first", mode: "plan" },
    ]);
  });

  it("collapses consecutive duplicate content across the active and archived lists", () => {
    const result = buildChatHistory(
      [{ role: "user", content: "same prompt" }],
      [{ role: "user", content: "same prompt" }],
    );

    expect(result).toEqual([{ content: "same prompt", mode: null }]);
  });

  it("filters out non-user roles and non-string content in both lists", () => {
    const result = buildChatHistory(
      [
        { role: "user", content: 42 },
        { role: "assistant", content: "not a user message" },
        { role: "user", content: "active user" },
      ],
      [
        { role: "user", content: null },
        { role: "tool", content: "tool result" },
        { role: "user", content: "archived user" },
      ],
    );

    expect(result).toEqual([
      { content: "active user", mode: null },
      { content: "archived user", mode: null },
    ]);
  });

  it("tolerates missing inputs and defaults a missing mode to null", () => {
    expect(buildChatHistory()).toEqual([]);
    expect(buildChatHistory(null, null)).toEqual([]);

    const result = buildChatHistory([
      { role: "user", content: "no mode", mode: undefined },
    ]);

    expect(result).toEqual([{ content: "no mode", mode: null }]);
  });
});
