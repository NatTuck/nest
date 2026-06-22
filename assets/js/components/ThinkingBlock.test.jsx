/**
 * ThinkingBlock component tests.
 *
 * Covers: null/empty thinking, collapsed-by-default, expand/collapse
 * on click, and the rendered thinking text.
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

  it("renders the Thinking label but not the content by default", () => {
    render(<ThinkingBlock thinking="I need to think about this carefully." />);

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
});
