import { describe, it, expect } from "vitest";
import { messageToMarkdown, formatApiLogsAsJson } from "./formatMessage.js";

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

  it("labels a backgrounded tool result and keeps a header-only result non-empty", () => {
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

  it("calls out an unrecognised part kind instead of dropping it", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "tool_arguments", text: "{}" }],
      }),
    ).toBe("*[unsupported part omitted from copy: tool_arguments]*");
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
});

describe("messageToMarkdown — legacy (no parts) shape", () => {
  it("derives content from a text part when no legacy content is present", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        parts: [{ kind: "text", text: "from parts" }],
      }),
    ).toBe("from parts");
  });

  it("excludes the legacy thinking field from an assistant message", () => {
    expect(
      messageToMarkdown({
        role: "assistant",
        thinking: "Let me think about this.",
        content: "Here is the answer.",
      }),
    ).toBe("Here is the answer.");
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
