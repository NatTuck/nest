/**
 * ThinkingBlock component tests.
 *
 * Covers: null/empty thinking, default expanded state (the
 * user explicitly wants the reasoning to remain visible after
 * the turn completes), expand/collapse on click, the typing
 * indicator, and the `aria-expanded` attribute.
 */
import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ThinkingBlock } from "./ThinkingBlock";

describe("ThinkingBlock", () => {
  it("returns null when thinking is undefined", () => {
    const { container } = render(<ThinkingBlock thinking={undefined} />);
    expect(container.firstChild).toBeNull();
  });

  it("returns null when thinking is an empty string", () => {
    const { container } = render(<ThinkingBlock thinking="" />);
    expect(container.firstChild).toBeNull();
  });

  describe("expanded-by-default", () => {
    // The box always starts expanded so the user sees the
    // reasoning (both during streaming and after the turn
    // finalizes). The user can collapse it manually.

    it("renders the Thinking label and the content", () => {
      render(
        <ThinkingBlock thinking="I need to think about this carefully." />,
      );

      expect(screen.getByText("Thinking")).toBeInTheDocument();
      expect(
        screen.getByText("I need to think about this carefully."),
      ).toBeInTheDocument();
    });

    it("is aria-expanded on first render regardless of isPartial", () => {
      const { rerender } = render(
        <ThinkingBlock thinking="live reasoning" isPartial={true} />,
      );
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "true",
      );

      // The user explicitly wanted the box to remain visible
      // after the turn ends, so the partial → final transition
      // does NOT collapse the box. (Previously, the parent used
      // a `key` change to force a re-mount and re-initialize
      // state; that's no longer needed — `useState(true)` is the
      // default regardless of `isPartial`.)
      rerender(<ThinkingBlock thinking="live reasoning" isPartial={false} />);
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "true",
      );
    });

    it("is aria-expanded on first render regardless of hasVisibleContent", () => {
      // Previously, a finalized message with visible content
      // started collapsed. Now it starts expanded in all cases.
      const { rerender } = render(
        <ThinkingBlock
          thinking="Some reasoning..."
          isPartial={false}
          hasVisibleContent={true}
        />,
      );
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "true",
      );

      rerender(
        <ThinkingBlock
          thinking="Some reasoning..."
          isPartial={false}
          hasVisibleContent={false}
        />,
      );
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "true",
      );
    });

    it("preserves the expanded state across a partial → final re-render with the same key", () => {
      // The parent used to pass `key={isPartial ? "partial" : "final"}`
      // to force a re-mount on the transition. Now the parent
      // passes no `key`, so the box keeps its internal state
      // (including any user-initiated collapse) across the
      // transition.
      const { rerender } = render(
        <ThinkingBlock thinking="live reasoning" isPartial={true} />,
      );
      // User collapses the box mid-stream.
      fireEvent.click(screen.getByRole("button", { name: /thinking/i }));
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "false",
      );

      // Re-render as finalized. The box stays collapsed because
      // we kept the same DOM node and the user explicitly
      // collapsed it.
      rerender(<ThinkingBlock thinking="live reasoning" isPartial={false} />);
      expect(screen.getByRole("button", { name: /thinking/i })).toHaveAttribute(
        "aria-expanded",
        "false",
      );
    });
  });

  describe("user toggles", () => {
    it("collapses the thinking text on click", () => {
      render(<ThinkingBlock thinking="The answer is 42." />);

      const toggleButton = screen.getByRole("button", { name: /thinking/i });
      fireEvent.click(toggleButton);
      expect(screen.queryByText("The answer is 42.")).toBeNull();
      expect(toggleButton).toHaveAttribute("aria-expanded", "false");
    });

    it("re-expands the thinking text on a second click", () => {
      render(<ThinkingBlock thinking="The answer is 42." />);

      const toggleButton = screen.getByRole("button", { name: /thinking/i });
      fireEvent.click(toggleButton);
      fireEvent.click(toggleButton);
      expect(screen.getByText("The answer is 42.")).toBeInTheDocument();
      expect(toggleButton).toHaveAttribute("aria-expanded", "true");
    });
  });

  describe("streaming indicator", () => {
    it("does not show the typing indicator when not partial", () => {
      render(<ThinkingBlock thinking="reasoning" isPartial={false} />);

      // The streaming indicator uses animate-bounce dots and
      // carries an aria-label of "Streaming thinking".
      expect(
        screen.queryByLabelText("Streaming thinking"),
      ).not.toBeInTheDocument();
    });

    it("shows the streaming indicator while partial", () => {
      render(<ThinkingBlock thinking="..." isPartial={true} />);

      // The indicator carries an aria-label so screen readers
      // can announce the streaming state.
      expect(screen.getByLabelText("Streaming thinking")).toBeInTheDocument();

      // Bouncing dots — visual cue.
      const dots = document.querySelectorAll(
        '[aria-label="Streaming thinking"] .animate-bounce',
      );
      expect(dots.length).toBe(3);
    });
  });
});
