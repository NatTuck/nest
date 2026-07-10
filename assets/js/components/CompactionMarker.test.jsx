/**
 * CompactionMarker Component Tests
 *
 * Covers:
 * - Renders nothing when marker is missing or archivedCount ≤ 0
 * - Renders nothing when history is empty
 * - Header is "History" (the new label)
 * - "Last compaction: X → Y" sub-line is present when token
 *   stats are set; "N earlier messages archived" fallback
 *   when no stats
 * - Show (N) count uses the `historyCount` prop, not the
 *   marker's `archivedCount` (the typical case after multiple
 *   compactions where the two diverge)
 * - Clicking the toggle expands to show the CollapsedHistory
 * - Clicking again collapses it
 * - data-testid/data attributes expose marker.index and archivedCount
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
    parts: [{ kind: "text", text: `archived message ${i + 1}` }],
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

    it("renders the History header", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );
      const title = screen.getByTestId("compaction-marker-title");
      expect(title.textContent).toBe("History");
    });

    it("renders the 'Last compaction: X → Y' sub-line when token stats are set", () => {
      render(
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
      const subtitle = screen.getByTestId("compaction-marker-subtitle");
      expect(subtitle.textContent).toContain("Last compaction");
      expect(subtitle.textContent).toContain("18,432");
      expect(subtitle.textContent).toContain("4,096");
    });

    it("falls back to 'Last compaction · N earlier messages archived' when stats are missing", () => {
      render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 4,
          }}
          history={buildHistory(4)}
        />,
      );
      const subtitle = screen.getByTestId("compaction-marker-subtitle");
      expect(subtitle.textContent).toContain("Last compaction");
      expect(subtitle.textContent).toContain("4 earlier messages archived");
    });

    it("uses singular 'message' wording in the fallback when archivedCount is 1", () => {
      render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 1,
          }}
          history={buildHistory(1)}
        />,
      );
      const subtitle = screen.getByTestId("compaction-marker-subtitle");
      expect(subtitle.textContent).toContain("1 earlier message archived");
    });
  });

  describe("Show (N) count", () => {
    it("uses the historyCount prop when provided, not marker.archivedCount", () => {
      // The marker.archivedCount is from one boundary
      // (e.g. 3 messages archived at this compaction); the
      // total history length is larger (e.g. 12 messages
      // across three compactions). The Show count uses the
      // total — that's the number of archived messages the
      // user is about to reveal.
      render(
        <CompactionMarker
          marker={{
            index: 11,
            role: "compaction",
            archivedCount: 3,
            tokensCompacted: 1000,
            tokensCompactedTo: 500,
          }}
          history={buildHistory(12)}
          historyCount={12}
        />,
      );
      expect(screen.getByText(/Show \(12\)/)).toBeInTheDocument();
    });

    it("falls back to history.length when historyCount is not provided", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(7)}
        />,
      );
      expect(screen.getByText(/Show \(7\)/)).toBeInTheDocument();
    });

    it("uses plural wording for multiple messages (aria-label)", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
          historyCount={3}
        />,
      );

      expect(screen.getByText(/Show \(3\)/)).toBeInTheDocument();
      const toggle = screen.getByTestId("compaction-marker-toggle");
      expect(toggle.getAttribute("aria-label")).toBe(
        "Show 3 archived messages",
      );
    });

    it("uses singular wording for one message (aria-label)", () => {
      render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 1 }}
          history={buildHistory(1)}
          historyCount={1}
        />,
      );

      expect(screen.getByText(/Show \(1\)/)).toBeInTheDocument();
      const toggle = screen.getByTestId("compaction-marker-toggle");
      expect(toggle.getAttribute("aria-label")).toBe("Show 1 archived message");
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

    it("omits the 'Last compaction' sub-line when expanded (so the layout doesn't squish it against the Hide button)", () => {
      render(
        <CompactionMarker
          marker={{
            index: 5,
            role: "compaction",
            archivedCount: 3,
            tokensCompacted: 12_000,
            tokensCompactedTo: 6_000,
          }}
          history={buildHistory(3)}
        />,
      );

      // Collapsed: sub-line is present (the entry point
      // info telling the user what they're about to see).
      expect(
        screen.getByTestId("compaction-marker-subtitle"),
      ).toBeInTheDocument();

      // Expand. The sub-line goes away — the user is now
      // looking at the full history with per-compaction
      // stats on each inline marker, and the summary
      // squished against the Hide button would be noise.
      fireEvent.click(screen.getByTestId("compaction-marker-toggle"));
      expect(
        screen.queryByTestId("compaction-marker-subtitle"),
      ).not.toBeInTheDocument();

      // The title and toggle stay.
      expect(screen.getByTestId("compaction-marker-title")).toHaveTextContent(
        "History",
      );
      expect(screen.getByTestId("compaction-marker-toggle")).toHaveTextContent(
        "Hide",
      );
    });

    it("renders the title and toggle on separate lines (button is NOT a flex-row sibling of the title)", () => {
      // Regression: the toggle button used to live in the
      // same flex row as the "History" title, which squished
      // the title against the button (and on narrow widths
      // the title text wrapped under the button). The
      // current layout puts the button on its OWN row below
      // the header so the title and the button never share
      // horizontal space. The toggle must not be a direct
      // child of the header flex row.
      const { container } = render(
        <CompactionMarker
          marker={{ index: 5, role: "compaction", archivedCount: 3 }}
          history={buildHistory(3)}
        />,
      );

      const marker = screen.getByTestId("compaction-marker");
      const title = screen.getByTestId("compaction-marker-title");
      const toggle = screen.getByTestId("compaction-marker-toggle");

      // The title and the toggle are both descendants of
      // the marker, but they should NOT share a parent
      // flex container. Walk up from the title and find the
      // closest ancestor that also contains the toggle —
      // that ancestor must be the outer marker, not a flex
      // row.
      const titleAncestors = new Set();
      let node = title.parentElement;
      while (node && node !== container) {
        titleAncestors.add(node);
        node = node.parentElement;
      }
      // The toggle's direct parent must NOT be in the
      // title's ancestor chain (otherwise they're flex
      // siblings).
      const toggleParent = toggle.parentElement;
      assert.isFalse(
        titleAncestors.has(toggleParent),
        "the toggle button must not share a flex parent with the title",
      );

      // And the marker still contains both (sanity check).
      assert.isTrue(marker.contains(title));
      assert.isTrue(marker.contains(toggle));
    });
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
        apiLogs: [],
      },
      {
        index: 1,
        role: "assistant",
        parts: [{ kind: "text", text: "Hi there" }],
        apiLogs: [],
      },
      {
        index: 2,
        role: "user",
        parts: [{ kind: "text", text: "How are you?" }],
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

    // Re-render with the same props (e.g. a parent re-render
    // from a new message arriving) — the expand state is
    // local to the component and should persist.
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
    // Only `tokensCompacted` set; `tokensCompactedTo` is
    // null → hits the falsy branch of `buildStatsLine/1`
    // and renders the non-stats header.
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

    // The non-stats path: "Last compaction · N earlier
    // messages archived".
    expect(
      screen
        .getByTestId("compaction-marker")
        .getAttribute("data-tokens-compacted-to"),
    ).toBe("");
    expect(
      screen.getByTestId("compaction-marker-subtitle").textContent,
    ).toContain("4 earlier messages archived");
  });

  it("renders numeric tokens via formatTokens when values are integers", () => {
    // `formatTokens/1` falls through to
    // `.toLocaleString("en-US")` on a finite number —
    // distinct from the null branch covered above.
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
    // The ternary at `count === 1 ? "" : "s"` is hit on
    // both branches via the legacy count line; the
    // saved-delta line also runs the same singular-vs-
    // plural switch, and the singular branch is tested
    // here.
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

    // Singular: "saved 1000 ... across 1 earlier message"
    expect(container.textContent).toContain("across 1 earlier message");
  });

  it("uses non-numeric token values via the null branch (formatTokens bailout)", () => {
    // Pass `tokensCompacted: "abc"` (a string, not a
    // number). `formatTokens/1` returns `null` for
    // non-finite inputs, and `buildStatsLine/1` then
    // returns `null` itself, rendering the legacy
    // "Last compaction · N earlier messages archived"
    // header.
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

    // The legacy sub-line is present, NOT the
    // "Last compaction: X → Y" stats line.
    expect(
      screen.getByTestId("compaction-marker-subtitle").textContent,
    ).toContain("3 earlier messages archived");
  });
});
