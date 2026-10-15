import { describe, it, expect } from "vitest";
import {
  messageToMarkdown,
  formatApiLogsAsJson,
  apiLogReplacer,
  MAX_INLINE_LOG_STRING,
} from "./formatMessage.js";

describe("messageToMarkdown — user messages", () => {
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

  it("strips the prefix from a user message's text part too", () => {
    expect(
      messageToMarkdown({
        role: "user",
        mode: "build",
        parts: [{ kind: "text", text: "[mode: build]\nHello" }],
      }),
    ).toBe("Hello");
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

  it("copies a user's own text verbatim, including a <think> they typed", () => {
    // A user message's body renders as-is (`Message.jsx` wraps its text
    // in a single Part.Text with the mode prefix stripped; it is not
    // routed through the think-splitting path), so the clipboard must
    // not silently drop a `<think>` the user typed.
    expect(
      messageToMarkdown({
        role: "user",
        parts: [{ kind: "text", text: "<think>not reasoning</think>hi" }],
      }),
    ).toBe("<think>not reasoning</think>hi");
  });

  it("strips the `[nest notice]` marker from a runtime notice row", () => {
    // A notice lands as a user row (the `:agent_user` shape, and the drain's
    // `:notice` path) with the marker after the mode prefix, or fused into an
    // assistant row with the ack (the `:user_agent` shape, where the marker is
    // at the head of the whole row). The clipboard shows what the bubble shows,
    // so the marker goes either way.
    expect(
      messageToMarkdown({
        role: "user",
        mode: "chat",
        parts: [
          {
            kind: "text",
            text: "[mode: chat]\n[nest notice]\nContext at 50%. Do not stop due to context concerns, continue working through compaction.",
          },
        ],
      }),
    ).toBe(
      "Context at 50%. Do not stop due to context concerns, continue working through compaction.",
    );

    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          {
            kind: "text",
            text: "[nest notice]\nContext at 25%. Okay, context noted.",
          },
        ],
      }),
    ).toBe("Context at 25%. Okay, context noted.");

    // A drain batch is its entries joined by a blank line, so a notice behind a
    // peer's entry heads the second body — the marker goes there too.
    expect(
      messageToMarkdown({
        role: "user",
        mode: "chat",
        parts: [
          {
            kind: "text",
            text: '[mode: chat]\n[Message from agent "peer"]\nmay I ask?\n\n[nest notice]\nContext at 50%.',
          },
        ],
      }),
    ).toBe('[Message from agent "peer"]\nmay I ask?\n\nContext at 50%.');
  });
});

describe("messageToMarkdown — whole message from parts", () => {
  it("serialises text, tool call and tool result in order, omitting thinking", () => {
    const out = messageToMarkdown({
      role: "assistant",
      parts: [
        { kind: "thinking", thinking: "secret reasoning" },
        { kind: "text", text: "Here is the answer." },
        {
          kind: "tool_use",
          id: "call_1",
          name: "shell-cmd",
          arguments: { command: "ls" },
        },
        {
          kind: "tool_result",
          toolCallId: "call_1",
          name: "shell-cmd",
          content: "file.txt",
          isError: false,
        },
      ],
    });

    expect(out).not.toContain("secret reasoning");
    expect(out).toBe(
      [
        "Here is the answer.",
        "",
        "**Tool call: `shell-cmd`**",
        "",
        "```json",
        "{",
        '  "command": "ls"',
        "}",
        "```",
        "",
        "**Tool result: `shell-cmd` — Success**",
        "",
        "```",
        "file.txt",
        "```",
      ].join("\n"),
    );
  });

  it("excludes a thinking part from an assistant message", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          { kind: "thinking", thinking: "hidden thought" },
          { kind: "text", text: "visible" },
        ],
      }),
    ).toBe("visible");
  });

  it("excludes <think> tags embedded in an assistant text part", () => {
    // The UI routes reasoning buried in a text part to the
    // ThinkingBlock (see `splitThinkFromParts`), so the clipboard
    // must not leak it.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "<think>secret</think>Answer." }],
      }),
    ).toBe("Answer.");

    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          { kind: "thinking", thinking: "hidden" },
          { kind: "text", text: "A<think>also hidden</think>B" },
        ],
      }),
    ).toBe("AB");
  });

  it("treats an orphan </think> in a text part as reasoning", () => {
    // Mirrors `splitThinkTags`: an unmatched closing tag starts a
    // thinking run to the end of the string.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "Visible.</think>Hidden." }],
      }),
    ).toBe("Visible.");
  });

  it("returns the marker for a text part that is entirely <think> reasoning", () => {
    // A text part whose whole content is reasoning is omitted like a
    // `thinking` part, so the copy must be legible rather than empty.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "<think>only reasoning</think>" }],
      }),
    ).toBe("*[thinking omitted from copy]*");

    // An unclosed `<think>` runs to the end of the string — also
    // reasoning.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "<think>only reasoning" }],
      }),
    ).toBe("*[thinking omitted from copy]*");
  });

  it("copies a system message's text verbatim, including <think> tags", () => {
    // `SystemMessageContent` renders a system message's raw text parts
    // with no split, so the clipboard must not drop tags that renderer
    // shows.
    expect(
      messageToMarkdown({
        role: "system",
        parts: [
          { kind: "text", text: "Use <think>tags</think> for reasoning." },
        ],
      }),
    ).toBe("Use <think>tags</think> for reasoning.");
  });

  it("strips <think> tags from a tool message's text part", () => {
    // A tool message's body goes through `textPartsFor`, which splits,
    // so the clipboard splits too.
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [{ kind: "text", text: "A<think>hidden</think>B" }],
      }),
    ).toBe("AB");
  });

  it("serialises a refusal part", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "refusal", refusal: "I can't help with that." }],
      }),
    ).toBe("I can't help with that.");
  });

  it("renders a tool call with no arguments as a header only", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          {
            kind: "tool_use",
            id: "call_1",
            name: "agents-list",
            arguments: {},
          },
        ],
      }),
    ).toBe("**Tool call: `agents-list`**");
  });

  it("renders a tool call whose arguments are still an empty streaming buffer as a header only", () => {
    // The real `applyToolUseStart` shape: `arguments` is `""` until
    // the first delta arrives.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          {
            kind: "tool_use",
            id: "call_1",
            name: "agents-list",
            arguments: "",
          },
        ],
      }),
    ).toBe("**Tool call: `agents-list`**");
  });

  it("renders a tool call with no name as `unknown`", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "tool_use", id: "call_1", arguments: {} }],
      }),
    ).toBe("**Tool call: `unknown`**");
  });

  it("renders a tool call whose arguments are still streaming as a string", () => {
    const out = messageToMarkdown({
      role: "assistant",
      parts: [
        {
          kind: "tool_use",
          id: "call_1",
          name: "file-write",
          arguments: '{"path":',
        },
      ],
    });
    expect(out).toContain("**Tool call: `file-write`**");
    expect(out).toContain('{"path":');
  });

  it("renders a tool call whose arguments arrive in the streaming `text` buffer", () => {
    const out = messageToMarkdown({
      role: "assistant",
      parts: [
        {
          kind: "tool_use",
          id: "call_1",
          name: "shell-cmd",
          arguments: null,
          text: '{"command":',
        },
      ],
    });
    expect(out).toContain("**Tool call: `shell-cmd`**");
    expect(out).toContain('{"command":');
  });

  it("renders a tool result's own arguments", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "shell-cmd",
          arguments: { command: "ls" },
          content: "ok",
          isError: false,
        },
      ],
    });
    expect(out).toContain("**Tool result: `shell-cmd` — Success**");
    expect(out).toContain('"command": "ls"');
    expect(out).toContain("ok");
  });

  it("renders a tool result body carried only in `text`", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "shell-cmd",
          text: "streamed body",
        },
      ],
    });
    expect(out).toContain("**Tool result: `shell-cmd` — Success**");
    expect(out).toContain("streamed body");
  });

  it("renders a tool result with no name as `unknown`", () => {
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [{ kind: "tool_result", toolCallId: "c1", content: "x" }],
      }),
    ).toBe(
      ["**Tool result: `unknown` — Success**", "", "```", "x", "```"].join(
        "\n",
      ),
    );
  });

  it("labels an error tool result", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "shell-cmd",
          content: "boom",
          isError: true,
        },
      ],
    });
    expect(out).toContain("**Tool result: `shell-cmd` — Error**");
    expect(out).toContain("boom");
  });

  it("labels a backgrounded or waiting tool result and keeps a header-only result non-empty", () => {
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "c1",
            name: "shell-cmd",
            content: "",
            state: "backgrounded",
          },
        ],
      }),
    ).toBe("**Tool result: `shell-cmd` — Backgrounded**");

    // A wait tool's result is the same kind of value: the call registered a
    // watch and its real result arrives later as a message (issue #54).
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "c2",
            name: "agents-wait",
            content: "",
            state: "waiting",
          },
        ],
      }),
    ).toBe("**Tool result: `agents-wait` — Waiting**");
  });

  it("renders an unrecognised tool-result state verbatim", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "shell-cmd",
          content: "x",
          state: "weird",
        },
      ],
    });
    expect(out).toContain(
      "**Tool result: `shell-cmd` — Unknown state (weird)**",
    );
  });

  it("escalates the code fence when the content contains a fence", () => {
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "c1",
            name: "shell-cmd",
            content: "```\ncode\n```",
            isError: false,
          },
        ],
      }),
    ).toBe(
      [
        "**Tool result: `shell-cmd` — Success**",
        "",
        "````",
        "```",
        "code",
        "```",
        "````",
      ].join("\n"),
    );
  });

  it("calls out a part kind this build does not know", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "mystery" }],
      }),
    ).toBe("*[unsupported part omitted from copy: mystery]*");
  });

  it("calls out a part with no `kind`", () => {
    expect(messageToMarkdown({ role: "assistant", parts: [{}] })).toBe(
      "*[unsupported part omitted from copy: unknown]*",
    );
  });

  it("renders a streaming `tool_arguments` accumulator part", () => {
    // `store/helpers.js` `newPart/2` produces this kind, carrying the
    // arguments JSON in `text`; it must not be reported as unsupported.
    const out = messageToMarkdown({
      role: "assistant",
      parts: [{ kind: "tool_arguments", text: '{"command":' }],
    });
    expect(out).toContain('{"command":');
    expect(out).not.toContain("unsupported part");
  });

  it("calls out a `tool_arguments` part with no payload instead of dropping it", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "tool_arguments", text: "" }],
      }),
    ).toBe("*[tool arguments omitted from copy]*");
  });

  it("emits a refusal in position among the other parts", () => {
    // Ordering is the core of the issue: a refusal sits where the
    // model produced it, between the surrounding text.
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [
          { kind: "text", text: "Before." },
          { kind: "refusal", refusal: "I can't do that." },
          { kind: "text", text: "After." },
        ],
      }),
    ).toBe("Before.\n\nI can't do that.\n\nAfter.");
  });

  it("derives content from a text part when no legacy content is present", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "from parts" }],
      }),
    ).toBe("from parts");
  });
});

describe("messageToMarkdown — no-text messages", () => {
  it("returns a marker for a thinking-only parts message", () => {
    const out = messageToMarkdown({
      role: "assistant",
      parts: [{ kind: "thinking", thinking: "deep thoughts" }],
    });
    expect(out).toBe("*[thinking omitted from copy]*");
    expect(out).not.toContain("deep thoughts");
  });

  it("returns a marker for a legacy thinking-only message", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "reasoning only",
        content: "",
      }),
    ).toBe("*[thinking omitted from copy]*");
  });

  it("returns a tool-result-only message legibly", () => {
    expect(
      messageToMarkdown({
        role: "tool",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "c1",
            name: "shell-cmd",
            content: "ok",
            isError: false,
          },
        ],
      }),
    ).toBe(
      ["**Tool result: `shell-cmd` — Success**", "", "```", "ok", "```"].join(
        "\n",
      ),
    );
  });

  it("returns an empty string when every part contributes nothing", () => {
    // Documented, not a bug: a malformed entry, a text part with no
    // text, and a refusal with no text each contribute nothing. With
    // no reasoning to explain the emptiness, the copy is legitimately
    // empty (the `thinking`-only case gets the marker above instead).
    expect(messageToMarkdown({ role: "assistant", parts: [null] })).toBe("");
    expect(
      messageToMarkdown({ role: "assistant", parts: [{ kind: "text" }] }),
    ).toBe("");
    expect(
      messageToMarkdown({ role: "assistant", parts: [{ kind: "refusal" }] }),
    ).toBe("");
    expect(
      messageToMarkdown({ role: "system", parts: [{ kind: "text" }] }),
    ).toBe("");
  });
});

describe("messageToMarkdown — legacy (no parts) shape", () => {
  it("excludes the legacy thinking field from an assistant message", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "Let me think about this.",
        content: "Here is the answer.",
      }),
    ).toBe("Here is the answer.");
  });

  it("excludes <think> tags from a legacy content string", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        content: "<think>secret</think>Answer.",
      }),
    ).toBe("Answer.");
  });

  it("returns the marker for legacy content that is entirely <think> reasoning", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        content: "<think>only reasoning</think>",
      }),
    ).toBe("*[thinking omitted from copy]*");
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
    expect(
      messageToMarkdown({ role: "assistant", content: "", thinking: "" }),
    ).toBe("");
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

  it("elides a media payload in place, naming its length", () => {
    // A request carrying an image has one multi-megabyte base64 string in it.
    // The block would build and lay out all of it, so it is elided — visibly,
    // with its length, rather than silently.
    const url = `data:image/png;base64,${"A".repeat(4_000)}`;

    const payload = {
      messages: [
        {
          role: "user",
          content: [{ type: "image_url", image_url: { url } }],
        },
      ],
    };

    const out = formatApiLogsAsJson([
      { id: "a", timestamp: "t", type: "request", payload },
    ]);

    expect(out).toContain(`[base64 payload elided: ${url.length} characters]`);
    // The rest of the request shape is untouched, so the log still shows what
    // was sent apart from the bytes themselves.
    expect(out).toContain('"role": "user"');
    expect(out).toContain('"type": "image_url"');
    expect(out).not.toContain("A".repeat(4_000));
  });
});

describe("messageToMarkdown — media parts", () => {
  const PNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

  it("emits a reference line, never the payload", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [
        {
          kind: "tool_result",
          toolCallId: "c1",
          name: "file-read",
          content: "Read it",
          isError: false,
        },
        {
          kind: "media",
          toolCallId: "c1",
          modality: "image",
          mediaType: "image/png",
          bytes: 68,
          data: PNG,
          path: "shot.png",
        },
      ],
    });

    expect(out).toContain("**Tool media: image/png · 68 bytes · shot.png**");
    // The bytes never reach the clipboard: a data URI is not useful there and
    // would swamp everything else in the copy.
    expect(out).not.toContain(PNG);
    expect(out).not.toContain("base64");
  });

  it("names what is missing rather than emitting a bare marker", () => {
    const out = messageToMarkdown({
      role: "tool",
      parts: [{ kind: "media", toolCallId: "c1", modality: "image" }],
    });

    expect(out).toContain("**Tool media: type not reported**");
  });
});

describe("apiLogReplacer", () => {
  it("leaves a short base64 string alone", () => {
    const short = "AAAA";
    expect(short.length).toBeLessThanOrEqual(MAX_INLINE_LOG_STRING);
    expect(apiLogReplacer("data", short)).toBe(short);
  });

  it("leaves a long string that is not a payload alone", () => {
    // Prose is long enough to be caught by a naive length check; its spaces
    // break the base64 run, which is what distinguishes it from a payload.
    const prose = "the quick brown fox ".repeat(300);
    expect(prose.length).toBeGreaterThan(MAX_INLINE_LOG_STRING);
    expect(apiLogReplacer("text", prose)).toBe(prose);
  });

  it("elides a bare base64 payload", () => {
    const payload = "iVBORw0KGgo".repeat(300);
    expect(apiLogReplacer("data", payload)).toBe(
      `[base64 payload elided: ${payload.length} characters]`,
    );
  });

  it("passes non-string values through unchanged", () => {
    expect(apiLogReplacer("n", 42)).toBe(42);
    expect(apiLogReplacer("b", true)).toBe(true);
    expect(apiLogReplacer("n", null)).toBe(null);
  });
});
