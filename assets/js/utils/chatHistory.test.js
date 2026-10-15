/**
 * Tests for `js/utils/chatHistory.js`.
 *
 * The helper powers the Ctrl/Cmd+Up chat-input history. It includes a
 * user-role row only when it carries `origin: "human"` (the rule is
 * fail-closed), pulls those from both the active session and the archived
 * (post-compaction) history, strips the `[mode: X]\n` prefix, orders them
 * most-recent-first, and collapses consecutive duplicates.
 */

import { describe, expect, it } from "vitest";
import { buildChatHistory } from "./chatHistory.js";

describe("buildChatHistory", () => {
  it("merges archived and active human messages most-recent-first, stripping the mode prefix", () => {
    const result = buildChatHistory(
      [
        {
          role: "user",
          origin: "human",
          content: "[mode: build]\nsecond",
          mode: "build",
        },
        { role: "assistant", content: "not a user message" },
      ],
      [
        {
          role: "user",
          origin: "human",
          content: "[mode: plan]\nfirst",
          mode: "plan",
        },
      ],
    );

    expect(result).toEqual([
      { content: "second", mode: "build" },
      { content: "first", mode: "plan" },
    ]);
  });

  it("collapses consecutive duplicate content across the active and archived lists", () => {
    const result = buildChatHistory(
      [{ role: "user", origin: "human", content: "same prompt" }],
      [{ role: "user", origin: "human", content: "same prompt" }],
    );

    expect(result).toEqual([{ content: "same prompt", mode: null }]);
  });

  it("filters out non-user roles and non-string content in both lists", () => {
    const result = buildChatHistory(
      [
        { role: "user", origin: "human", content: 42 },
        { role: "assistant", content: "not a user message" },
        { role: "user", origin: "human", content: "active user" },
      ],
      [
        { role: "user", origin: "human", content: null },
        { role: "tool", content: "tool result" },
        { role: "user", origin: "human", content: "archived user" },
      ],
    );

    expect(result).toEqual([
      { content: "active user", mode: null },
      { content: "archived user", mode: null },
    ]);
  });

  it("derives prompt text from parts for wire-format archived rows", () => {
    // `chat:history` returns archived user rows in the wire format
    // (`parts`, no flat `content`), so the helper must read through
    // `messageText` for the recall list to include them.
    const result = buildChatHistory(
      [
        {
          role: "user",
          origin: "human",
          parts: [{ kind: "text", text: "[mode: build]\nactive" }],
          mode: "build",
        },
      ],
      [
        {
          role: "user",
          origin: "human",
          parts: [{ kind: "text", text: "[mode: plan]\narchived" }],
          mode: "plan",
        },
      ],
    );

    expect(result).toEqual([
      { content: "active", mode: "build" },
      { content: "archived", mode: "plan" },
    ]);
  });

  it("includes a human prompt sent while the agent was busy", () => {
    // A message queued behind a busy agent is still the human's own words, so
    // the server tags it `origin: "human"` on the drained path.
    const result = buildChatHistory([
      {
        role: "user",
        origin: "human",
        content: "[mode: build]\nqueued prompt",
        mode: "build",
      },
    ]);

    expect(result).toEqual([{ content: "queued prompt", mode: "build" }]);
  });

  it("excludes user rows that are not tagged as human (fail-closed)", () => {
    // Peer deliveries, notices and runtime reminders are user-role rows with
    // no `origin`; legacy rows predate the marker; a stray non-human origin is
    // not human either. None of them is a prompt the human typed.
    const result = buildChatHistory(
      [
        {
          role: "user",
          content: '[mode: build]\n[Message from agent "X"]\nhi',
          mode: "build",
        },
        {
          role: "user",
          content: "[mode: build]\nlegacy prompt",
          mode: "build",
        },
        { role: "user", origin: "agent", content: "[mode: build]\npeer" },
        { role: "user", origin: "runtime", content: "[mode: build]\nnotice" },
        {
          role: "user",
          origin: "human",
          content: "[mode: build]\nreal prompt",
          mode: "build",
        },
      ],
      [
        {
          role: "user",
          content: "[mode: plan]\nlegacy archived",
          mode: "plan",
        },
      ],
    );

    expect(result).toEqual([{ content: "real prompt", mode: "build" }]);
  });

  it("tolerates missing inputs and defaults a missing mode to null", () => {
    expect(buildChatHistory()).toEqual([]);
    expect(buildChatHistory(null, null)).toEqual([]);

    const result = buildChatHistory([
      { role: "user", origin: "human", content: "no mode", mode: undefined },
    ]);

    expect(result).toEqual([{ content: "no mode", mode: null }]);
  });

  it("strips the `[nest notice]` marker, matching what the bubble showed", () => {
    // A notice row is never `origin: "human"`, so the server's marker never
    // reaches a human entry — but the bubble strips a leading marker
    // unconditionally, so the recall list must do the same or a human who
    // typed one would get different text back than they saw.
    const result = buildChatHistory([
      {
        role: "user",
        origin: "human",
        content: "[mode: build]\n[nest notice]\ntyped by the human",
        mode: "build",
      },
    ]);

    expect(result).toEqual([{ content: "typed by the human", mode: "build" }]);
  });
});
