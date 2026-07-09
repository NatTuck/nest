/**
 * CompactionMarker Component Tests
 *
 * Covers:
 * - Renders nothing when marker is missing or archivedCount ≤ 0
 * - Renders nothing when history is empty
 * - Shows "N archived messages" with the marker count
 * - Clicking the toggle expands to show the CollapsedHistory
 * - Clicking again collapses it
 * - data-testid/data attributes expose marker.index and archivedCount
 * - Hidden state hides the CollapsedHistory (only toggle button visible)
 * - Singular vs plural wording
 */

import { describe, it, expect, afterEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { CompactionMarker } from "./CompactionMarker";

afterEach(() => cleanup());

function buildHistory(n) {
  return Array.from({ length: n }, (_, i) => ({
    index: i,
    role: i % 2 === 0 ? "user" : "assistant",
    content: `archived message ${i + 1}`,
    apiLogs: [],
  }));
}

describe("CompactionMarker", () => {
  describe("empty states", () => {
    it("renders nothing when marker is null", () => {
      const { container } = render(
        <CompactionMarker marker={null} history={buildHistory(3)} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when marker is undefined", () => {
      const { container } = render(
        <CompactionMarker history={buildHistory(3)} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when archivedCount is 0", () => {
      const { container } = render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 0 }}
          history={buildHistory(3)}
        />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when archivedCount is negative", () => {
      const { container } = render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: -1 }}
          history={buildHistory(3)}
        />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when history is empty", () => {
      const { container } = render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={[]}
        />,
      );
      expect(container.firstChild).toBeNull();
    });
  });

  describe("rendering", () => {
    it("renders the marker with the archived count", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 7 }}
          history={buildHistory(7)}
        />,
      );

      const marker = screen.getByTestId("compaction-marker");
      expect(marker).toBeInTheDocument();
      expect(marker.getAttribute("data-archived-count")).toBe("7");
      expect(marker.getAttribute("data-marker-index")).toBe("5");
    });

    it("uses plural wording for multiple messages", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      expect(screen.getByText(/3 earlier messages/)).toBeInTheDocument();
      expect(screen.getByText(/Show \(3\)/)).toBeInTheDocument();
    });

    it("uses singular wording for one message", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 1 }}
          history={buildHistory(1)}
        />,
      );

      expect(screen.getByText(/1 earlier message\b/)).toBeInTheDocument();
      expect(screen.getByText(/Show \(1\)/)).toBeInTheDocument();
    });

    it("is collapsed by default (CollapsedHistory not visible)", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      const toggle = screen.getByTestId("compaction-marker-toggle");
      expect(toggle.getAttribute("aria-expanded")).toBe("false");
      expect(screen.queryByTestId("collapsed-history")).not.toBeInTheDocument();
    });
  });

  describe("expand/collapse", () => {
    it("clicking the toggle expands and reveals the CollapsedHistory", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      fireEvent.click(screen.getByTestId("compaction-marker-toggle"));

      expect(screen.getByTestId("collapsed-history")).toBeInTheDocument();
      expect(
        screen
          .getByTestId("compaction-marker-toggle")
          .getAttribute("aria-expanded"),
      ).toBe("true");
      expect(screen.getByText(/Hide/)).toBeInTheDocument();
    });

    it("clicking again collapses the CollapsedHistory", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      const toggle = screen.getByTestId("compaction-marker-toggle");
      fireEvent.click(toggle);
      expect(screen.getByTestId("collapsed-history")).toBeInTheDocument();

      fireEvent.click(toggle);
      expect(screen.queryByTestId("collapsed-history")).not.toBeInTheDocument();
      expect(toggle.getAttribute("aria-expanded")).toBe("false");
    });

    it("renders the archived messages when expanded", () => {
      const history = [
        {
          index: 0,
          role: "user",
          parts: [{ kind: "text", text: "Hello" }],
          content: "Hello",
          apiLogs: [],
        },
        {
          index: 1,
          role: "assistant",
          parts: [{ kind: "text", text: "Hi there" }],
          content: "Hi there",
          apiLogs: [],
        },
        {
          index: 2,
          role: "user",
          parts: [{ kind: "text", text: "How are you?" }],
          content: "How are you?",
          apiLogs: [],
        },
      ];
      render(
        <CompactionMarker
          marker={{ index: 3, role: "compaction", archivedCount: 3 }}
          history={history}
        />,
      );

      fireEvent.click(screen.getByTestId("compaction-marker-toggle"));

      const bubbles = screen.getAllByTestId("history-message");
      expect(bubbles).toHaveLength(3);
      expect(bubbles[0].textContent).toContain("Hello");
      expect(bubbles[1].textContent).toContain("Hi there");
      expect(bubbles[2].textContent).toContain("How are you?");
    });

    it("remains expanded across re-renders with the same props", () => {
      const { rerender } = render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      fireEvent.click(screen.getByTestId("compaction-marker-toggle"));
      expect(screen.getByTestId("collapsed-history")).toBeInTheDocument();

      // Re-render with the same props (e.g. a parent re-render from
      // a new message arriving) — the expand state is local to the
      // component and should persist.
      rerender(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      expect(screen.getByTestId("collapsed-history")).toBeInTheDocument();
    });
  });

  describe("token-stats rendering branches", () => {
    it("falls back to the legacy text when statsCompacted is missing", () => {
      // Only `tokensCompacted` set; `tokensCompactedTo` is null →
      // hits the falsy branch of `buildStatsLine/1` and renders
      // the non-stats header.
      render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 4,
            tokensCompacted: 18_432,
            tokensCompactedTo: null,
          }}
          history={buildHistory(4)}
        />,
      );

      // The non-stats path: "Context compacted" + count line.
      // (Verified indirectly — the data-tokens-compacted-to attr
      // stays empty since the saved delta isn't computed.)
      expect(
        screen
          .getByTestId("compaction-marker")
          .getAttribute("data-tokens-compacted-to"),
      ).toBe("");
    });

    it("renders numeric tokens via formatTokens when values are integers", () => {
      // `formatTokens/1` falls through to `.toLocaleString("en-US")`
      // on a finite number — distinct from the null branch
      // covered above.
      const { container } = render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 3,
            tokensCompacted: 18_432,
            tokensCompactedTo: 4_096,
          }}
          history={buildHistory(3)}
        />,
      );

      expect(container.textContent).toContain("18,432");
      expect(container.textContent).toContain("4,096");
    });

    it("uses singular 'message' wording in the saved-delta line when archivedCount is 1", () => {
      // The ternary at `count === 1 ? "" : "s"` is hit on both
      // branches via the legacy count line; the saved-delta line
      // also runs the same singular-vs-plural switch, and the
      // singular branch is tested here.
      const { container } = render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 1,
            tokensCompacted: 1_500,
            tokensCompactedTo: 500,
          }}
          history={buildHistory(1)}
        />,
      );

      // Singular: "saved 1000 tokens across 1 earlier message"
      expect(container.textContent).toContain("across 1 earlier message");
      // Plural branch is covered by other tests.
    });

    it("uses non-numeric token values via the null branch (formatTokens bailout)", () => {
      // Pass `tokensCompacted: "abc"` (a string, not a number).
      // `formatTokens/1` returns `null` for non-finite inputs,
      // and `buildStatsLine/1` then returns `null` itself,
      // rendering the legacy "Context compacted" header.
      render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 3,
            tokensCompacted: "abc",
            tokensCompactedTo: 4_096,
          }}
          history={buildHistory(3)}
        />,
      );

      // The legacy header + count line should be present,
      // NOT the "Compaction: X tokens compacted to Y" line.
      expect(screen.queryByText(/Compaction: /)).not.toBeInTheDocument();
      expect(
        screen.getByText(/3 earlier messages archived/),
      ).toBeInTheDocument();
    });
  });
});
