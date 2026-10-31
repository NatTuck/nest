/**
 * Tests for `messageParts.js` — the helpers that derive
 * canonical `parts` shapes from wire-format messages and
 * back into the flat legacy fields some components still
 * read (thinking, toolCalls, toolResults, textParts).
 *
 * `userPartsFor/1` is the user-row counterpart (issue #139): it splits a user
 * row's text parts into prose and a backgrounded command's own output, which
 * the wire marks with `commandOutputParts` — indexes into `parts`, so the
 * original index is what the blocks carry. A malformed value there is a server
 * bug and throws rather than being ignored.
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
  splitReasoning,
  thinkingFor,
  textPartsFor,
  messageContentPartsFor,
  userPartsFor,
  toolCallsFromParts,
  toolResultsFromParts,
  mediaFromParts,
  formatToolCall,
  LONG_FIELD_THRESHOLD,
} from "./messageParts.js";

describe("splitReasoning", () => {
  // The rule, in order: a `Part.Thinking` is the reasoning channel and the text
  // is never scanned; else an assistant's leading matched `<think>` block is
  // legacy reasoning; else the text is prose.

  it("takes a Part.Thinking as the reasoning channel and leaves the text alone", () => {
    const text = { kind: "text", text: "<think>still prose</think>after" };
    const result = splitReasoning({
      role: "assistant",
      parts: [{ kind: "thinking", thinking: "real reasoning" }, text],
    });

    expect(result.thinking).toBe("real reasoning");
    // The text is not scanned at all: the tag stays, because the row already
    // said where its reasoning lives.
    expect(result.parts[1]).toBe(text);
  });

  it("throws when a message carries more than one Part.Thinking", () => {
    // `build_assistant_parts/1` is the only producer and emits at most one,
    // first. A second is a server bug; concatenating them would invent
    // reasoning the row does not have.
    expect(() =>
      splitReasoning({
        role: "assistant",
        parts: [
          { kind: "thinking", thinking: "first" },
          { kind: "thinking", thinking: "second" },
        ],
      }),
    ).toThrow(/at most one thinking part, got 2/);
  });

  it("takes an assistant's leading matched block as legacy reasoning", () => {
    const result = splitReasoning({
      role: "assistant",
      parts: [{ kind: "text", text: "<think>secret</think>Answer." }],
    });

    expect(result.thinking).toBe("secret");
    expect(result.parts).toEqual([{ kind: "text", text: "Answer." }]);
  });

  it("keeps the parts' indexes so commandOutputParts still lines up", () => {
    const result = splitReasoning({
      role: "assistant",
      parts: [
        { kind: "text", text: "<think>secret</think>Answer." },
        { kind: "tool_use", id: "x", name: "shell-cmd" },
      ],
    });

    expect(result.parts).toHaveLength(2);
    expect(result.parts[1]).toEqual({
      kind: "tool_use",
      id: "x",
      name: "shell-cmd",
    });
  });

  it("does not scan a user's or a system's text", () => {
    for (const role of ["user", "system", "tool"]) {
      const parts = [{ kind: "text", text: "<think>mine</think>hi" }];
      expect(splitReasoning({ role, parts })).toEqual({
        thinking: null,
        parts,
      });
    }
  });

  it("does not scan text that only mentions the tag", () => {
    // The regression: a message reading "see <think> for details" lost the rest
    // of its text to the thinking channel.
    const parts = [{ kind: "text", text: "see <think> for details" }];
    expect(splitReasoning({ role: "assistant", parts })).toEqual({
      thinking: null,
      parts,
    });
  });

  it("tolerates a missing message or parts", () => {
    expect(splitReasoning(null)).toEqual({ thinking: null, parts: [] });
    expect(splitReasoning({})).toEqual({ thinking: null, parts: [] });
  });
});

describe("thinkingFor", () => {
  it("returns null for null/undefined messages", () => {
    expect(thinkingFor(null)).toBeNull();
    expect(thinkingFor(undefined)).toBeNull();
  });

  it("returns the single Part.Thinking's content", () => {
    expect(
      thinkingFor({
        parts: [{ kind: "thinking", thinking: "reasoning" }],
      }),
    ).toBe("reasoning");
  });

  it("falls back to message.thinking when parts has no thinking entries", () => {
    expect(thinkingFor({ thinking: "legacy" })).toBe("legacy");
  });

  it("finds an assistant's legacy leading block", () => {
    expect(
      thinkingFor({
        role: "assistant",
        parts: [{ kind: "text", text: "<think>legacy reasoning</think>hi" }],
      }),
    ).toBe("legacy reasoning");
  });

  it("never invents a box for a user row that mentions the tag", () => {
    expect(
      thinkingFor({
        role: "user",
        parts: [{ kind: "text", text: "<think>mine</think>hi" }],
      }),
    ).toBeNull();
  });
});

describe("textPartsFor", () => {
  it("takes an assistant's legacy leading block out of the body", () => {
    expect(
      textPartsFor({
        role: "assistant",
        parts: [{ kind: "text", text: "<think>reasoning</think>after" }],
      }),
    ).toEqual([{ kind: "text", text: "after" }]);
  });

  it("leaves a mid-text tag in the body", () => {
    // Copied verbatim: it is prose, not framing.
    expect(
      textPartsFor({
        role: "assistant",
        parts: [{ kind: "text", text: "before<think>r</think>after" }],
      }),
    ).toEqual([{ kind: "text", text: "before<think>r</think>after" }]);
  });

  it("drops the thinking part from the body", () => {
    expect(
      textPartsFor({
        role: "assistant",
        parts: [
          { kind: "thinking", thinking: "r" },
          { kind: "text", text: "hi" },
        ],
      }),
    ).toEqual([{ kind: "text", text: "hi" }]);
  });
  it("preserves non-text/non-thinking parts (e.g. tool_use) for downstream renderers", () => {
    const toolUse = { kind: "tool_use", id: "x", name: "shell-cmd" };
    expect(textPartsFor({ parts: [toolUse] })).toEqual([toolUse]);
  });

  it("strips the header from a row whose mode it names", () => {
    // Every user-role body is headered now, and this function is what a
    // non-user row's parts go through: a runtime notice is a `user` row, but a
    // transcript recorded before that still puts one on an assistant row, and a
    // peer delivery in a batch is a body whose head is its header.
    expect(
      textPartsFor({
        mode: "act",
        parts: [
          {
            kind: "text",
            text: "[From nest runtime | mode: act]\nContext at 50%.",
          },
        ],
      }),
    ).toEqual([{ kind: "text", text: "Context at 50%." }]);

    // The guard: a clause that disagrees with the row's own mode keeps the
    // header, so a disagreement stays visible.
    expect(
      textPartsFor({
        mode: "plan",
        parts: [
          {
            kind: "text",
            text: "[From nest runtime | mode: act]\nContext at 50%.",
          },
        ],
      }),
    ).toEqual([
      {
        kind: "text",
        text: "[From nest runtime | mode: act]\nContext at 50%.",
      },
    ]);
  });

  it("strips the `[nest notice]` marker from a runtime notice's row", () => {
    // The fused `assistant(notice + ack)` row is an assistant row whose text
    // starts with the server's marker (`Nest.Agents.Agent.NoticePairInjector`);
    // the operator must see the notice, not the wire framing. Only the head is
    // touched — a later text part is left alone.
    expect(
      textPartsFor({
        parts: [{ kind: "text", text: "[nest notice]\nContext at 50%." }],
      }),
    ).toEqual([{ kind: "text", text: "Context at 50%." }]);

    expect(
      textPartsFor({
        parts: [
          { kind: "text", text: "[nest notice]\nContext at 50%." },
          { kind: "text", text: "and the model echoed [nest notice]\nagain" },
        ],
      }),
    ).toEqual([
      { kind: "text", text: "Context at 50%." },
      { kind: "text", text: "and the model echoed [nest notice]\nagain" },
    ]);

    // A non-text head is skipped rather than mis-stripped.
    expect(
      textPartsFor({
        parts: [
          { kind: "tool_use", id: "x", name: "shell-cmd" },
          { kind: "text", text: "[nest notice]\nContext at 50%." },
        ],
      }),
    ).toEqual([
      { kind: "tool_use", id: "x", name: "shell-cmd" },
      { kind: "text", text: "Context at 50%." },
    ]);
  });
});

describe("messageContentPartsFor", () => {
  it("drops media parts while keeping every other part in place", () => {
    // The helper's whole contract: `MessageContent` renders the media part
    // itself, so the caller that renders media beside it must not hand it one
    // (issue #115). The other non-text parts are inert there and stay.
    const toolUse = { kind: "tool_use", id: "x", name: "shell-cmd" };
    const toolResult = {
      kind: "tool_result",
      toolCallId: "c1",
      name: "file-read",
      content: "r",
    };
    expect(
      messageContentPartsFor({
        parts: [
          { kind: "text", text: "done" },
          { kind: "media", toolCallId: "c1", modality: "image", data: "AAAA" },
          toolUse,
          toolResult,
        ],
      }),
    ).toEqual([{ kind: "text", text: "done" }, toolUse, toolResult]);
  });

  it("returns the text parts unchanged when there is no media", () => {
    expect(
      messageContentPartsFor({ parts: [{ kind: "text", text: "hello" }] }),
    ).toEqual([{ kind: "text", text: "hello" }]);
  });

  it("tolerates a missing message or parts", () => {
    expect(messageContentPartsFor(null)).toEqual([]);
    expect(messageContentPartsFor({})).toEqual([]);
  });
});

describe("userPartsFor", () => {
  it("returns one text block per text part, with the framing stripped from each", () => {
    // A drained batch is one user row holding one body per entry, and each body
    // carries its own header. Per part is the same removal the joined renderer
    // performed: a header heads a body and every part starts a body.
    expect(
      userPartsFor({
        role: "user",
        mode: "act",
        parts: [
          { kind: "text", text: "[From agent peer | mode: act]\nfirst body" },
          {
            kind: "text",
            text: "\n\n[From agent other | mode: act]\nsecond body",
          },
        ],
      }),
    ).toEqual([
      { kind: "text", text: "first body", index: 0 },
      { kind: "text", text: "\n\nsecond body", index: 1 },
    ]);

    // The retired label's mode clause goes too (the row's badge shows the mode).
    expect(
      userPartsFor({
        role: "user",
        mode: "act",
        parts: [
          {
            kind: "text",
            text: '[Message from agent "peer" | mode: act]\nmay I ask?',
          },
        ],
      }),
    ).toEqual([
      {
        kind: "text",
        text: '[Message from agent "peer"]\nmay I ask?',
        index: 0,
      },
    ]);
  });

  it("marks the part `commandOutputParts` names by its index in `parts`", () => {
    // The indexes are into `message.parts`, not into the returned blocks, so a
    // `media` part ahead of the text shifts nothing: the output is part 2 here
    // and block 1.
    expect(
      userPartsFor({
        role: "user",
        mode: "act",
        parts: [
          { kind: "media", toolCallId: "c1", modality: "image", data: "AAAA" },
          { kind: "text", text: "[From nest runtime | mode: act]\nfinished:" },
          { kind: "text", text: "# output" },
        ],
        commandOutputParts: [2],
      }),
    ).toEqual([
      // `index` is the part's index in `parts` (2), not its index among the
      // blocks (1) — that is the mapping the wire's `commandOutputParts` uses.
      { kind: "text", text: "finished:", index: 1 },
      { kind: "output", text: "# output", index: 2 },
    ]);
  });

  it("does not assume the output part is last", () => {
    // A drained batch can hold several bodies, so a later body may follow the
    // command's output.
    expect(
      userPartsFor({
        role: "user",
        mode: "act",
        parts: [
          { kind: "text", text: "[From nest runtime | mode: act]\nfinished:" },
          { kind: "text", text: "out" },
          { kind: "text", text: "\n\n[From agent peer | mode: act]\nhi" },
        ],
        commandOutputParts: [1],
      }),
    ).toEqual([
      { kind: "text", text: "finished:", index: 0 },
      { kind: "output", text: "out", index: 1 },
      { kind: "text", text: "\n\nhi", index: 2 },
    ]);
  });

  it("falls back to one text block for a row persisted before the parts model", () => {
    expect(
      userPartsFor({
        role: "user",
        mode: "act",
        content: "[From user | mode: act]\nlegacy body",
      }),
    ).toEqual([{ kind: "text", text: "legacy body", index: 0 }]);

    // `parts` without a text part reads `content` too — that fallback lives in
    // `messageText`, and the row must not render blank.
    expect(
      userPartsFor({ role: "user", parts: [], content: "only content" }),
    ).toEqual([{ kind: "text", text: "only content", index: 0 }]);

    expect(userPartsFor(null)).toEqual([{ kind: "text", text: "", index: 0 }]);
  });

  it("throws when commandOutputParts is not an array of non-negative integers", () => {
    // A malformed value is a server bug. Ignoring it would silently render a
    // command's output as prose, which is the bug this helper exists to fix, so
    // it is reported instead (AGENTS.md, "UI Transparency").
    const base = { role: "user", parts: [{ kind: "text", text: "x" }] };

    expect(() => userPartsFor({ ...base, commandOutputParts: "1" })).toThrow(
      /commandOutputParts must be an array of parts indexes, got "1"/,
    );
    // `null` is not "absent": the wire contract omits the key when there is no
    // command output.
    expect(() => userPartsFor({ ...base, commandOutputParts: null })).toThrow(
      /commandOutputParts must be an array of parts indexes, got null/,
    );
    expect(() => userPartsFor({ ...base, commandOutputParts: [-1] })).toThrow(
      /must name non-negative integer indexes into parts, got -1/,
    );
    expect(() => userPartsFor({ ...base, commandOutputParts: ["0"] })).toThrow(
      /must name non-negative integer indexes into parts, got "0"/,
    );
  });

  it("throws when commandOutputParts names a part that is not text", () => {
    expect(() =>
      userPartsFor({
        role: "user",
        parts: [
          { kind: "text", text: "prose" },
          { kind: "media", toolCallId: "c1", modality: "image", data: "AAAA" },
        ],
        commandOutputParts: [1],
      }),
    ).toThrow(/commandOutputParts names parts\[1\], which is not a text part/);

    // An index past the end of `parts` names nothing at all, which is equally
    // wrong.
    expect(() =>
      userPartsFor({
        role: "user",
        parts: [{ kind: "text", text: "prose" }],
        commandOutputParts: [7],
      }),
    ).toThrow(/commandOutputParts names parts\[7\], which is not a text part/);
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
        state: null,
      },
    ]);

    // A result that carries a state keeps it verbatim: the panel badges on it,
    // so a value this build does not know must not be dropped here.
    const backgrounded = toolResultsFromParts([
      {
        kind: "tool_result",
        toolCallId: "call_2",
        name: "shell-cmd",
        content: "moved to the background",
        isError: false,
        state: "backgrounded",
      },
    ]);
    expect(backgrounded).toEqual([
      {
        tool_call_id: "call_2",
        name: "shell-cmd",
        content: "moved to the background",
        is_error: false,
        state: "backgrounded",
      },
    ]);
  });
});

describe("mediaFromParts", () => {
  it("returns null when there is no media part", () => {
    expect(mediaFromParts(null)).toBeNull();
    expect(mediaFromParts(undefined)).toBeNull();
    expect(mediaFromParts([{ kind: "text", text: "x" }])).toBeNull();
    expect(
      mediaFromParts([
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "file-read",
          content: "r",
        },
      ]),
    ).toBeNull();
  });

  it("derives the media shape, with `path` null when the wire omitted it", () => {
    const base = {
      kind: "media",
      toolCallId: "c1",
      modality: "image",
      mediaType: "image/png",
      bytes: 68,
      data: "AAAA",
    };

    expect(mediaFromParts([base])).toEqual([
      {
        tool_call_id: "c1",
        modality: "image",
        mediaType: "image/png",
        bytes: 68,
        data: "AAAA",
        path: null,
      },
    ]);

    // `path` is the one optional key on the wire; when present it rides
    // through verbatim rather than being normalized away.
    expect(mediaFromParts([{ ...base, path: "shot.png" }])[0].path).toBe(
      "shot.png",
    );
  });

  it("keeps every media part, in order, ignoring the other kinds", () => {
    const media = mediaFromParts([
      { kind: "text", text: "x" },
      { kind: "media", toolCallId: "c1", modality: "image", data: "a" },
      {
        kind: "tool_result",
        toolCallId: "c1",
        name: "file-read",
        content: "r",
      },
      { kind: "media", toolCallId: "c2", modality: "image", data: "b" },
    ]);

    expect(media.map((m) => m.tool_call_id)).toEqual(["c1", "c2"]);
    expect(media.map((m) => m.data)).toEqual(["a", "b"]);
  });
});
