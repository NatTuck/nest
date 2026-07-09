/**
 * CollapsedHistory Component Tests
 *
 * Covers:
 * - Renders nothing when history is empty
 * - Renders nothing when history is null/undefined
 * - Filters out EARLIER compaction markers; renders the LAST
 *   one as a dedicated marker box at the end of the visible
 *   list (carries archivedCount + token-stats fields).
 * - Renders a bubble per non-compaction message with the
 *   correct role.
 * - Renders tool call / tool result counts when present.
 * - Roles map to the correct avatar letter and label.
 * - Tolerates missing timestamps / unknown roles.
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

    it("renders the LAST compaction marker as a marker box when only markers are present", () => {
      const history = [
        { index: 0, role: "compaction", archivedCount: 5 },
        { index: 1, role: "compaction", archivedCount: 2 },
      ];
      render(<CollapsedHistory history={history} />);
      // Only one marker box should render (the LAST one);
      // earlier markers are filtered out.
      const boxes = screen.getAllByTestId("history-compaction-marker");
      expect(boxes).toHaveLength(1);
      expect(boxes[0].getAttribute("data-marker-index")).toBe("1");
    });
  });

  describe("rendering messages", () => {
    it("renders a bubble for each non-compaction message", () => {
      const history = buildHistory([
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi" },
        { role: "user", content: "How are you?" },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getAllByTestId("history-message")).toHaveLength(3);
    });

    it("skips EARLIER compaction markers and renders the LAST one as a marker box", () => {
      const history = [
        ...buildHistory([
          { role: "user", content: "Hello" },
          { role: "compaction", archivedCount: 2 },
          { role: "user", content: "After compaction" },
        ]),
      ];
      render(<CollapsedHistory history={history} />);

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles).toHaveLength(2);
      expect(bubbles[0].textContent).toContain("Hello");
      expect(bubbles[1].textContent).toContain("After compaction");

      const markerBoxes = screen.getAllByTestId("history-compaction-marker");
      expect(markerBoxes).toHaveLength(1);
      // The marker box renders AFTER the user/assistant bubbles
      // (it's the last item in the visible list).
      const collapsed = screen.getByTestId("collapsed-history");
      expect(
        collapsed.children[collapsed.children.length - 1].getAttribute(
          "data-testid",
        ),
      ).toBe("history-compaction-marker");
    });

    it("uses the correct role label per message", () => {
      const history = buildHistory([
        { role: "user", content: "u" },
        { role: "assistant", content: "a" },
        { role: "system", content: "s" },
        { role: "tool", content: "t" },
      ]);
      render(<CollapsedHistory history={history} />);

      expect(screen.getByText("You")).toBeInTheDocument();
      expect(screen.getByText("Assistant")).toBeInTheDocument();
      expect(screen.getByText("System")).toBeInTheDocument();
      expect(screen.getByText("Tool Result")).toBeInTheDocument();
    });

    it("sets data-role on each bubble", () => {
      const history = buildHistory([
        { role: "user", content: "u" },
        { role: "tool", content: "t" },
      ]);
      render(<CollapsedHistory history={history} />);

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles[0].getAttribute("data-role")).toBe("user");
      expect(bubbles[1].getAttribute("data-role")).toBe("tool");
    });
  });

  describe("tool call / tool result counts", () => {
    it("shows tool call count when present", () => {
      const history = buildHistory([
        {
          role: "assistant",
          content: "running tools",
          toolCalls: [{ id: "1" }, { id: "2" }, { id: "3" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText(/3 tool calls/)).toBeInTheDocument();
    });

    it("uses singular wording for one tool call", () => {
      const history = buildHistory([
        {
          role: "assistant",
          content: "running one tool",
          toolCalls: [{ id: "1" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText(/1 tool call\b/)).toBeInTheDocument();
    });

    it("shows tool result count when present", () => {
      const history = buildHistory([
        {
          role: "tool",
          content: "results",
          toolResults: [{ tool_call_id: "1" }, { tool_call_id: "2" }],
        },
      ]);
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText(/2 tool results/)).toBeInTheDocument();
    });
  });

  describe("edge cases", () => {
    it("tolerates unknown roles by using a fallback label", () => {
      const history = buildHistory([{ role: "alien", content: "👽" }]);
      render(<CollapsedHistory history={history} />);
      // The bubble should still render; the role label falls back to the
      // role string itself
      expect(screen.getByText("alien")).toBeInTheDocument();
    });
  });

  describe("compaction marker box (last-entry only)", () => {
    it("renders the marker box's archivedCount line when no token stats are provided", () => {
      const history = [{ index: 0, role: "compaction", archivedCount: 7 }];
      render(<CollapsedHistory history={history} />);
      const box = screen.getByTestId("history-compaction-marker");
      expect(box.textContent).toContain("7 earlier messages archived");
    });

    it("renders the marker box's token-stats line when tokens_compacted/tokens_compacted_to are set", () => {
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

    it("uses singular wording when archivedCount is 1", () => {
      const history = [{ index: 0, role: "compaction", archivedCount: 1 }];
      render(<CollapsedHistory history={history} />);
      const box = screen.getByTestId("history-compaction-marker");
      expect(box.textContent).toContain("1 earlier message archived");
    });

    it("tolerates missing timestamps", () => {
      const history = [
        { index: 0, role: "user", content: "no ts", apiLogs: [] },
      ];
      render(<CollapsedHistory history={history} />);
      // No crash; the message still renders
      expect(screen.getByText("no ts")).toBeInTheDocument();
    });

    it("tolerates a malformed timestamp without crashing", () => {
      // `formatTimestamp/1` falls back to passing through the
      // value when `new Date(<garbage>)` throws — covered when
      // a message carries a string that Date can't parse. The
      // exact text isn't easily assertable (the rendered DOM
      // splits the value across multiple elements); the only
      // contract pinned here is "doesn't crash" + "the bubble
      // still renders".
      const history = [
        {
          index: 0,
          role: "user",
          content: "ts-bad",
          timestamp: "not-a-real-date",
          apiLogs: [],
        },
      ];
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText("ts-bad")).toBeInTheDocument();
    });

    it("renders a normal visible list when history has no compaction markers", () => {
      // Hits the `lastCompactionIdx >= 0 ? ... : null` falsy
      // branch (no marker → `lastMarker === null`). The
      // `!history || history.length === 0` early-return is NOT
      // hit because history has items; the conditional `find`
      // returns -1 and the truthy branch produces `null`.
      const history = [
        { index: 0, role: "user", content: "Hello", apiLogs: [] },
        { index: 1, role: "assistant", content: "Hi", apiLogs: [] },
      ];

      render(<CollapsedHistory history={history} />);

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles).toHaveLength(2);
      expect(
        screen.queryByTestId("history-compaction-marker"),
      ).not.toBeInTheDocument();
    });

    it("strips the [mode: X]\\n prefix from archived user messages", () => {
      // Server-side ChatPipeline.build_user_messages/3 intentionally
      // prefixes every persisted user message with `[mode: <name>]\n`.
      // Archived (post-compaction) user messages carry the same wire
      // form, so the history view strips the prefix on render.
      const history = [
        {
          index: 0,
          role: "user",
          content: "[mode: build]\nHello there",
          mode: "build",
          apiLogs: [],
        },
      ];
      render(<CollapsedHistory history={history} />);
      const bubble = screen.getByTestId("history-message");
      expect(bubble.textContent).toContain("Hello there");
      expect(bubble.textContent).not.toContain("[mode: build]");
    });
  });
});
