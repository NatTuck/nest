/**
 * Tests for `js/utils/chatHistory.js`.
 *
 * The helper powers the Ctrl/Cmd+Up chat-input history. It includes a
 * user-role row only when it carries `origin: "human"` **and** `composed:
 * true` (the rule is fail-closed) — the first marks the human's words, which
 * the UI also produces on their behalf, and the second marks the ones they
 * typed. It pulls those from both the active session and the archived
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
          composed: true,
          content: "[mode: build]\nsecond",
          mode: "build",
        },
        { role: "assistant", content: "not a user message" },
      ],
      [
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "[mode: plan]\nfirst",
          mode: "plan",
        },
      ],
    );

    expect(result).toEqual([{ content: "second" }, { content: "first" }]);
  });

  it("collapses consecutive duplicate content across the active and archived lists", () => {
    const result = buildChatHistory(
      [
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "same prompt",
        },
      ],
      [
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "same prompt",
        },
      ],
    );

    expect(result).toEqual([{ content: "same prompt" }]);
  });

  it("filters out non-user roles and non-string content in both lists", () => {
    const result = buildChatHistory(
      [
        { role: "user", origin: "human", composed: true, content: 42 },
        { role: "assistant", content: "not a user message" },
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "active user",
        },
      ],
      [
        { role: "user", origin: "human", composed: true, content: null },
        { role: "tool", content: "tool result" },
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "archived user",
        },
      ],
    );

    expect(result).toEqual([
      { content: "active user" },
      { content: "archived user" },
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
          composed: true,
          parts: [{ kind: "text", text: "[mode: build]\nactive" }],
          mode: "build",
        },
      ],
      [
        {
          role: "user",
          origin: "human",
          composed: true,
          parts: [{ kind: "text", text: "[mode: plan]\narchived" }],
          mode: "plan",
        },
      ],
    );

    expect(result).toEqual([{ content: "active" }, { content: "archived" }]);
  });

  it("includes a human prompt sent while the agent was busy", () => {
    // A message queued behind a busy agent is still the human's own words, so
    // the server tags it `origin: "human"` on the drained path.
    const result = buildChatHistory([
      {
        role: "user",
        origin: "human",
        composed: true,
        content: "[mode: build]\nqueued prompt",
        mode: "build",
      },
    ]);

    expect(result).toEqual([{ content: "queued prompt" }]);
  });

  it("excludes user rows that are not tagged as human (fail-closed)", () => {
    // Peer deliveries, notices and runtime reminders are user-role rows with
    // no `origin`; legacy rows predate the marker; a stray non-human origin is
    // not human either. None of them is a prompt the human typed.
    //
    // The last one is the case this file exists for now: `origin: "human"`
    // without `composed` is the human's *words* produced by the UI — a decision
    // answer, an explain request — and recalling one would hand them a
    // paragraph they never typed.
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
          content:
            "[mode: build]\nDecisions answered:\n- Which database?: Postgres",
          mode: "build",
        },
        {
          role: "user",
          origin: "human",
          composed: true,
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

    expect(result).toEqual([{ content: "real prompt" }]);
  });

  it("tolerates missing inputs, and a row whose mode is absent strips no prefix", () => {
    expect(buildChatHistory()).toEqual([]);
    expect(buildChatHistory(null, null)).toEqual([]);

    const result = buildChatHistory([
      {
        role: "user",
        origin: "human",
        composed: true,
        content: "no mode",
        mode: undefined,
      },
    ]);

    expect(result).toEqual([{ content: "no mode" }]);
  });

  it("strips the header, matching what the bubble showed", () => {
    // A human entry is a single-sender row, so the server states its sender and
    // mode in a header. The bubble drops it, so the recall list must too — and
    // only when the clause agrees with the row's own `mode`.
    expect(
      buildChatHistory([
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "[From user | mode: act]\ntyped by the human",
          mode: "act",
        },
      ]),
    ).toEqual([{ content: "typed by the human" }]);

    expect(
      buildChatHistory([
        {
          role: "user",
          origin: "human",
          composed: true,
          content: "[From user | mode: act]\ntyped by the human",
          mode: "plan",
        },
      ]),
    ).toEqual([{ content: "[From user | mode: act]\ntyped by the human" }]);
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
        composed: true,
        content: "[mode: build]\n[nest notice]\ntyped by the human",
        mode: "build",
      },
    ]);

    expect(result).toEqual([{ content: "typed by the human" }]);
  });
});
