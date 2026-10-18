/**
 * Tests for `SpacePausedBanner` — the visible half of the space edit's latch.
 *
 * A paused space holds turns and tool calls, which from the outside looks like a
 * stuck agent. The banner is the transparency rule's answer: it says the space is
 * paused, and why.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen } from "@testing-library/react";

let pausedSpaces = [];

vi.mock("../store", () => ({
  useStore: (selector) => selector({ pausedSpaces }),
}));

import { SpacePausedBanner } from "./SpacePausedBanner";

beforeEach(() => {
  pausedSpaces = [];
});

describe("SpacePausedBanner", () => {
  it("renders nothing when the space is not paused", () => {
    const { container } = render(<SpacePausedBanner spaceId={7} />);

    expect(container).toBeEmptyDOMElement();
  });

  it("says the space is paused, and why, while its environment is edited", () => {
    pausedSpaces = [7];

    render(<SpacePausedBanner spaceId={7} spaceName="My Space" />);

    expect(screen.getByRole("status").textContent).toMatch(
      /My Space is paused/,
    );
    // The consequence, not just the state: what the user's message and the
    // agent's tools are doing.
    const text = screen.getByRole("status").textContent;
    expect(text).toMatch(/a new message waits/);
    expect(text).toMatch(/cancelled/);
    expect(text).toMatch(/Nothing is lost/);
  });

  it("ignores another space's pause", () => {
    pausedSpaces = [8];

    const { container } = render(<SpacePausedBanner spaceId={7} />);

    expect(container).toBeEmptyDOMElement();
  });
});
