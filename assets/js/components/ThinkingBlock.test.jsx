/**
 * ThinkingBlock component tests.
 *
 * Covers: null/empty thinking, default collapsed state,
 * auto-expand when `isPartial` is true, expand/collapse on
 * click, the typing indicator, and the `aria-expanded`
 * attribute.
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

  describe("collapsed-by-default (isPartial: false)", () => {
    it("renders the Thinking label but not the content", () => {
      render(
        <ThinkingBlock thinking="I need to think about this carefully." />,
      );

      expect(screen.getByText("Thinking")).toBeInTheDocument();
      expect(
        screen.queryByText("I need to think about this carefully."),
      ).toBeNull();
    });

    it("expands to show the thinking text on click", () => {
      render(<ThinkingBlock thinking="The answer is 42." />);

      fireEvent.click(screen.getByRole("button", { name: /thinking/i }));

      expect(screen.getByText("The answer is 42.")).toBeInTheDocument();
    });

    it("collapses the thinking text on a second click", () => {
      render(<ThinkingBlock thinking="The answer is 42." />);

      const toggleButton = screen.getByRole("button", { name: /thinking/i });
      fireEvent.click(toggleButton);
      expect(screen.getByText("The answer is 42.")).toBeInTheDocument();

      fireEvent.click(toggleButton);
      expect(screen.queryByText("The answer is 42.")).toBeNull();
    });

    it("exposes the expanded state via aria-expanded", () => {
      render(<ThinkingBlock thinking="reasoning" />);

      const button = screen.getByRole("button", { name: /thinking/i });
      expect(button).toHaveAttribute("aria-expanded", "false");

      fireEvent.click(button);
      expect(button).toHaveAttribute("aria-expanded", "true");
    });

    it("does not show the typing indicator", () => {
      render(<ThinkingBlock thinking="reasoning" />);

      // The streaming indicator uses animate-bounce dots and
      // carries an aria-label of "Streaming thinking".
      expect(
        screen.queryByLabelText("Streaming thinking"),
      ).not.toBeInTheDocument();
    });
  });

  describe("auto-expanded (isPartial: true)", () => {
    it("starts expanded so the user can watch the reasoning stream in", () => {
      render(
        <ThinkingBlock thinking="I am still thinking..." isPartial={true} />,
      );

      expect(screen.getByText("I am still thinking...")).toBeInTheDocument();
    });

    it("can still be collapsed manually by the user", () => {
      render(
        <ThinkingBlock thinking="I am still thinking..." isPartial={true} />,
      );

      const button = screen.getByRole("button", { name: /thinking/i });
      expect(button).toHaveAttribute("aria-expanded", "true");

      fireEvent.click(button);
      expect(button).toHaveAttribute("aria-expanded", "false");
      expect(
        screen.queryByText("I am still thinking..."),
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

  describe("re-mount on the partial → final transition", () => {
    // The parent passes `key={isPartial ? "partial" : "final"}`
    // so the box re-mounts (and `useState(isPartial ||
    // !hasVisibleContent)` re-initializes) when the message
    // transitions out of streaming. Simulate that here.
    it("starts expanded when mounted as partial, collapsed when re-mounted as final (with content)", () => {
      const { rerender } = render(
        <ThinkingBlock
          key="partial"
          thinking="live reasoning"
          isPartial={true}
        />,
      );
      expect(screen.getByText("live reasoning")).toBeInTheDocument();

      // Re-mount with the new key. `useState(isPartial ||
      // !hasVisibleContent)` runs again with `isPartial: false`
      // and `hasVisibleContent: true` (the default), so the box
      // is collapsed.
      rerender(
        <ThinkingBoxFinal
          key="final"
          thinking="live reasoning"
          isPartial={false}
        />,
      );
      // The user is no longer watching the stream, but they
      // can still click to expand and see the captured
      // reasoning.
      expect(screen.queryByText("live reasoning")).toBeNull();
      expect(
        screen.getByRole("button", { name: /thinking/i }),
      ).toBeInTheDocument();
    });
  });

  describe("auto-expanded on final (hasVisibleContent: false)", () => {
    // Some reasoning models (e.g. MiniMax) produce a
    // thinking-only response: the assistant message has
    // `thinking` set and `content: nil`. Without this behavior
    // the user would see a collapsed "Thinking" label with no
    // visible text and no way to know there was a response. The
    // box auto-expands in this case so the user actually sees
    // the model's response.

    it("starts expanded on a thinking-only response so the user sees the model's reply", () => {
      render(
        <ThinkingBlock
          thinking="The user wants me to add the feature."
          isPartial={false}
          hasVisibleContent={false}
        />,
      );

      const button = screen.getByRole("button", { name: /thinking/i });
      expect(button).toHaveAttribute("aria-expanded", "true");
      expect(
        screen.getByText("The user wants me to add the feature."),
      ).toBeInTheDocument();
    });

    it("collapses by default on a normal response that has visible content", () => {
      render(
        <ThinkingBlock
          thinking="Some reasoning..."
          isPartial={false}
          hasVisibleContent={true}
        />,
      );

      const button = screen.getByRole("button", { name: /thinking/i });
      expect(button).toHaveAttribute("aria-expanded", "false");
      // Content is hidden until the user clicks.
      expect(screen.queryByText("Some reasoning...")).toBeNull();
    });

    it("the user can still collapse the auto-expanded thinking-only box", () => {
      render(
        <ThinkingBlock
          thinking="Reasoning"
          isPartial={false}
          hasVisibleContent={false}
        />,
      );

      const button = screen.getByRole("button", { name: /thinking/i });
      expect(button).toHaveAttribute("aria-expanded", "true");

      fireEvent.click(button);
      expect(button).toHaveAttribute("aria-expanded", "false");
      expect(screen.queryByText("Reasoning")).toBeNull();
    });
  });
});

// Tiny alias so the re-mount test above can assert against a
// fresh component identity (matches the `key` change in
// production).
function ThinkingBoxFinal(props) {
  return <ThinkingBlock {...props} />;
}
