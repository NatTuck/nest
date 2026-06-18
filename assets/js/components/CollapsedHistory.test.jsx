/**
 * CollapsedHistory Component Tests
 *
 * Covers:
 * - Renders nothing when history is empty
 * - Renders nothing when history is null/undefined
 * - Filters out compaction markers (handled by parent)
 * - Shows "No archived messages" when only compaction markers exist
 * - Renders a bubble per message with the correct role
 * - Renders tool call / tool result counts when present
 * - Roles map to the correct avatar letter and label
 * - Tolerates missing timestamps / unknown roles
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

    it("shows a placeholder when only compaction markers are present", () => {
      const history = [
        { index: 0, role: "compaction", archivedCount: 5 },
        { index: 1, role: "compaction", archivedCount: 2 },
      ];
      render(<CollapsedHistory history={history} />);
      expect(screen.getByText(/No archived messages/)).toBeInTheDocument();
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

    it("skips compaction markers in the visible list", () => {
      const history = buildHistory([
        { role: "user", content: "Hello" },
        { role: "compaction", archivedCount: 2 },
        { role: "user", content: "After compaction" },
      ]);
      render(<CollapsedHistory history={history} />);

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles).toHaveLength(2);
      expect(bubbles[0].textContent).toContain("Hello");
      expect(bubbles[1].textContent).toContain("After compaction");
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

    it("tolerates missing timestamps", () => {
      const history = [
        { index: 0, role: "user", content: "no ts", apiLogs: [] },
      ];
      render(<CollapsedHistory history={history} />);
      // No crash; the message still renders
      expect(screen.getByText("no ts")).toBeInTheDocument();
    });
  });
});
