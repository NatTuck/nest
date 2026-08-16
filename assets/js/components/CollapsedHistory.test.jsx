/**
 * CollapsedHistory Component Tests
 *
 * Covers:
 * - Renders nothing when history is empty / null / undefined
 * - Renders EVERY compaction marker inline, in order (not just
 *   the last one — that filter was removed when the renderer
 *   was rewritten to show the full sequence)
 * - Renders a bubble per non-marker message with the correct
 *   role label and avatar letter
 * - System messages render via SystemMessageContent (20-line
 *   truncation + "Expand N more lines" toggle), NOT as the
 *   untruncated raw text the previous version showed
 * - User messages read from `parts` (the wire format), not
 *   from a flat `content` field, and strip the `[mode: X]\n`
 *   prefix
 * - Assistant messages extract thinking from `parts` and
 *   render a ThinkingBlock; tool_use parts render via
 *   ToolCalls; apiLogs render via ApiLogsBlock
 * - Tool messages render via ToolResults with full content
 * - Tolerates missing timestamps / unknown roles
 * - Interleaved messages + markers render in original order
 */

import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { CollapsedHistory } from "./CollapsedHistory";

afterEach(() => cleanup());

function buildHistory(items) {
  return items.map((m, i) => ({
    index: i,
    timestamp: "2024-01-01T00:00:00Z",
    apiLogs: [],
    ...m,
  }));
}

describe("CollapsedHistory", () => {
  describe("empty states", () => {
    it("renders nothing when history is null", () => {
      const { container } = render(<CollapsedHistory history={null} />);
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when history is undefined", () => {
      const { container } = render(<CollapsedHistory />);
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when history is an empty array", () => {
      const { container } = render(<CollapsedHistory history={[]} />);
      expect(container.firstChild).toBeNull();
    });
  });

  describe("rendering messages", () => {
    it("renders a bubble for each non-marker message", () => {
      const history = buildHistory([
        { role: "user", parts: [{ kind: "text", text: "Hello" }] },
        { role: "assistant", parts: [{ kind: "text", text: "Hi" }] },
        { role: "user", parts: [{ kind: "text", text: "How are you?" }] },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getAllByTestId("history-message")).toHaveLength(3);
    });

    it("uses the correct role label per message", () => {
      const history = buildHistory([
        { role: "user", parts: [{ kind: "text", text: "u" }] },
        { role: "assistant", parts: [{ kind: "text", text: "a" }] },
        { role: "system", parts: [{ kind: "text", text: "s" }] },
        {
          role: "tool",
          parts: [{ kind: "tool_result", toolCallId: "1", content: "t" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);

      expect(screen.getByText("You")).toBeInTheDocument();
      expect(screen.getByText("Assistant")).toBeInTheDocument();
      expect(screen.getByText("System")).toBeInTheDocument();
      expect(screen.getByText("Tool Result")).toBeInTheDocument();
    });

    it("sets data-role on each bubble", () => {
      const history = buildHistory([
        { role: "user", parts: [{ kind: "text", text: "u" }] },
        {
          role: "tool",
          parts: [{ kind: "tool_result", toolCallId: "1", content: "t" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles[0].getAttribute("data-role")).toBe("user");
      expect(bubbles[1].getAttribute("data-role")).toBe("tool");
    });

    it("renders every compaction marker inline, in order, when interleaved with messages", () => {
      // Three compactions, three messages between them. Every
      // marker renders inline in the order it appears in the
      // history array.
      const history = [
        { index: 0, role: "user", parts: [{ kind: "text", text: "Hello" }] },
        {
          index: 1,
          role: "compaction",
          archivedCount: 1,
          tokensCompacted: 1000,
          tokensCompactedTo: 500,
        },
        {
          index: 2,
          role: "user",
          parts: [{ kind: "text", text: "After first compaction" }],
        },
        {
          index: 3,
          role: "compaction",
          archivedCount: 2,
          tokensCompacted: 2000,
          tokensCompactedTo: 800,
        },
        {
          index: 4,
          role: "user",
          parts: [{ kind: "text", text: "After second compaction" }],
        },
        {
          index: 5,
          role: "compaction",
          archivedCount: 1,
          tokensCompacted: 500,
          tokensCompactedTo: 250,
        },
      ];
      render(<CollapsedHistory history={history} />);

      // Three bubbles (one per non-marker message)
      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles).toHaveLength(3);
      expect(bubbles[0].textContent).toContain("Hello");
      expect(bubbles[1].textContent).toContain("After first compaction");
      expect(bubbles[2].textContent).toContain("After second compaction");

      // Three marker boxes (every marker, not just the last)
      const markerBoxes = screen.getAllByTestId("history-compaction-marker");
      expect(markerBoxes).toHaveLength(3);
      expect(markerBoxes[0].getAttribute("data-marker-index")).toBe("1");
      expect(markerBoxes[1].getAttribute("data-marker-index")).toBe("3");
      expect(markerBoxes[2].getAttribute("data-marker-index")).toBe("5");
    });
  });

  describe("user message content", () => {
    it("reads user content from parts (the wire format), not from a flat content field", () => {
      // The wire format has no flat `content` field; the user
      // text lives in `parts: [{kind: "text", text: "..."}]`.
      // The history bubble reads from parts, not content, so
      // the message renders with its text.
      const history = buildHistory([
        {
          role: "user",
          parts: [{ kind: "text", text: "Hello there" }],
          mode: "chat",
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("Hello there");
    });

    it("strips the [mode: X]\\n prefix from archived user messages", () => {
      // Server-side ChatPipeline.build_user_messages/3
      // intentionally prefixes every persisted user message
      // with `[mode: <name>]\n`. Archived (post-compaction)
      // user messages carry the same wire form, so the
      // history view strips the prefix on render.
      const history = buildHistory([
        {
          role: "user",
          parts: [{ kind: "text", text: "[mode: build]\nHello there" }],
          mode: "build",
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("Hello there");
      expect(bubble.textContent).not.toContain("[mode: build]");
    });
  });

  describe("system message rendering", () => {
    it("renders system message text via SystemMessageContent", () => {
      // SystemMessageContent truncates at 20 lines + adds an
      // "Expand N more lines" toggle. Short system messages
      // render as plain markdown.
      const history = buildHistory([
        {
          role: "system",
          parts: [{ kind: "text", text: "You are a helpful assistant." }],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("You are a helpful assistant.");
    });

    it("truncates long system messages and renders the Expand button", () => {
      // Build a 25-line system message; SystemMessageContent
      // shows the first 20 lines and a "Expand 5 more lines"
      // button.
      const longText = Array.from(
        { length: 25 },
        (_, i) => `line ${i + 1}`,
      ).join("\n");
      const history = buildHistory([
        { role: "system", parts: [{ kind: "text", text: longText }] },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      // First 20 lines visible
      expect(bubble.textContent).toContain("line 1");
      expect(bubble.textContent).toContain("line 20");
      // Last 5 lines hidden
      expect(bubble.textContent).not.toContain("line 25");
      // Expand button is present with the right count
      expect(bubble.textContent).toContain("Expand 5 more lines");
    });
  });

  describe("assistant message rendering", () => {
    it("extracts thinking from parts and renders ThinkingBlock", () => {
      // The wire format puts thinking in `parts`; the
      // history bubble extracts it and renders a ThinkingBlock.
      const history = buildHistory([
        {
          role: "assistant",
          parts: [
            { kind: "thinking", thinking: "Let me think about this." },
            { kind: "text", text: "Here is the answer." },
          ],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("Let me think about this.");
      expect(bubble.textContent).toContain("Here is the answer.");
    });

    it("splits <think>...</think> blocks buried in Part.Text into ThinkingBlock", () => {
      // Some models emit the reasoning inline as
      // `<think>...</think>` text inside a `Part.Text` rather
      // than as a separate `Part.Thinking` entry. The history
      // bubble splits the text, routes the inner content to
      // ThinkingBlock, and renders only the surrounding
      // text via MessageContent.
      const history = buildHistory([
        {
          role: "assistant",
          parts: [
            {
              kind: "text",
              text: "before<think>reasoning here</think>after",
            },
          ],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      // Thinking content is rendered
      expect(bubble.textContent).toContain("reasoning here");
      // The visible text is split around the think block
      expect(bubble.textContent).toContain("before");
      expect(bubble.textContent).toContain("after");
      // No raw <think> markers in the rendered text
      expect(bubble.textContent).not.toContain("<think>");
      expect(bubble.textContent).not.toContain("</think>");
    });

    it("routes stray </think>\n\n text in Part.Text to the ThinkingBlock (orphan closing)", () => {
      // Regression: the OpenAI-style model occasionally
      // emits `</think>\n\n` as part of the response (a
      // closing tag without a matching opener). The history
      // bubble routes the orphan's tail to the thinking
      // channel so the user doesn't see raw `</think>`
      // characters in the visible reply.
      const history = buildHistory([
        {
          role: "assistant",
          parts: [{ kind: "text", text: "hello</think>\n\nworld" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      // The orphan + tail went to thinking (rendered as
      // collapsed reasoning), not the visible text
      expect(bubble.textContent).not.toContain("</think>");
      // The visible text retains the prefix
      expect(bubble.textContent).toContain("hello");
    });

    it("renders tool_use parts via ToolCalls", () => {
      const history = buildHistory([
        {
          role: "assistant",
          parts: [
            { kind: "text", text: "Running a tool" },
            {
              kind: "tool_use",
              id: "call_1",
              name: "shell-cmd",
              arguments: { command: "ls" },
            },
          ],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      // ToolCalls renders the tool name + a JSON preview of
      // the arguments
      expect(screen.getByText(/Using tool: shell-cmd/)).toBeInTheDocument();
      expect(screen.getByText(/"command"/)).toBeInTheDocument();
    });
  });

  describe("tool message rendering", () => {
    it("renders tool_result parts via ToolResults (full content, not just a count)", () => {
      // The previous version only showed a "1 tool result"
      // count; the new version renders the full content via
      // ToolResults.
      const history = buildHistory([
        {
          role: "tool",
          parts: [
            {
              kind: "tool_result",
              toolCallId: "call_1",
              name: "shell-cmd",
              content: "file1.txt\nfile2.txt",
              isError: false,
            },
          ],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("Success: shell-cmd");
      expect(bubble.textContent).toContain("file1.txt");
      expect(bubble.textContent).toContain("file2.txt");
    });
  });

  describe("api logs", () => {
    it("renders apiLogs via ApiLogsBlock when present", () => {
      const apiLogs = [
        {
          id: "0.000",
          timestamp: "2024-01-01T00:00:00Z",
          type: "request",
          payload: { model: "gpt-4" },
        },
      ];
      const history = buildHistory([
        { role: "assistant", parts: [{ kind: "text", text: "Hi" }], apiLogs },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText(/API Logs \(1\)/)).toBeInTheDocument();
    });
  });

  describe("edge cases", () => {
    it("tolerates unknown roles by using a fallback label", () => {
      const history = buildHistory([{ role: "alien", parts: [] }]);
      render(<CollapsedHistory history={history} />);
      // The bubble still renders; the role label falls back to
      // the role string itself.
      expect(screen.getByText("alien")).toBeInTheDocument();
    });

    it("tolerates missing timestamps", () => {
      const history = [
        { index: 0, role: "user", parts: [{ kind: "text", text: "no ts" }] },
      ];
      render(<CollapsedHistory history={history} />);
      // No crash; the message still renders
      expect(screen.getByText("no ts")).toBeInTheDocument();
    });
  });

  describe("compaction marker box", () => {
    it("renders a marker box for every role:compaction entry in order", () => {
      const history = [
        {
          index: 0,
          role: "compaction",
          archivedCount: 5,
          tokensCompacted: 18_432,
          tokensCompactedTo: 4_096,
        },
        {
          index: 1,
          role: "compaction",
          archivedCount: 3,
          tokensCompacted: 12_345,
          tokensCompactedTo: 6_789,
        },
      ];
      render(<CollapsedHistory history={history} />);
      // Both markers render (not just the last).
      const boxes = screen.getAllByTestId("history-compaction-marker");
      expect(boxes).toHaveLength(2);
      expect(boxes[0].getAttribute("data-marker-index")).toBe("0");
      expect(boxes[1].getAttribute("data-marker-index")).toBe("1");
    });

    it("renders the marker box's token-stats line when set", () => {
      const history = [
        {
          index: 0,
          role: "compaction",
          archivedCount: 4,
          tokensCompacted: 18_432,
          tokensCompactedTo: 4_096,
        },
      ];
      render(<CollapsedHistory history={history} />);
      const stats = screen.getByTestId("history-compaction-stats");
      expect(stats.textContent).toContain("18,432");
      expect(stats.textContent).toContain("4,096");
    });

    it("renders the saved delta when tokensCompacted > tokensCompactedTo", () => {
      const history = [
        {
          index: 0,
          role: "compaction",
          archivedCount: 3,
          tokensCompacted: 12_345,
          tokensCompactedTo: 6_789,
        },
      ];
      render(<CollapsedHistory history={history} />);
      const box = screen.getByTestId("history-compaction-marker");
      // saved = 12_345 - 6_789 = 5_556
      expect(box.textContent).toContain("5,556");
    });
  });
});
