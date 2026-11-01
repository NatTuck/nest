/**
 * Tests for `js/components/ChatHeader.jsx`.
 *
 * Covers the agent name/vocation heading, the clickable model chip
 * (provider prefix, `[missing]` fallback, and the `model_missing`
 * highlight), the parent lineage link, and the change-model error.
 * `TokenUsageChip` is mocked; its behaviour has its own tests.
 */

import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { ChatHeader } from "./ChatHeader";

vi.mock("./TokenUsageChip", () => ({
  // `className` is forwarded: the header folds the chip into its phone
  // disclosure by passing one, and that is what these tests assert on.
  TokenUsageChip: ({ className }) => (
    <div data-testid="usage-chip" className={className} />
  ),
}));

function header(overrides = {}) {
  const props = {
    name: "alpha",
    vocation: undefined,
    model: undefined,
    agentState: "idle",
    changeModelError: null,
    parentName: null,
    depth: 0,
    spaceSlug: "my-space",
    usage: null,
    descendantUsage: null,
    totalUsage: null,
    contextLimit: null,
    status: "connected",
    streaming: false,
    onModelPickerOpen: vi.fn(),
    getStatusLabel: () => "Idle",
    ...overrides,
  };
  return (
    <MemoryRouter>
      <ChatHeader {...props} />
    </MemoryRouter>
  );
}

describe("ChatHeader", () => {
  beforeEach(cleanup);

  it("folds the phone header into one line and opens the rest from the chevron", () => {
    // A phone with a browser toolbar and the OS nav bar has well under 844px; the
    // four-line header left the transcript about two lines of text. Below `lg` the
    // header is the name, the status dot and a chevron, and everything else is a
    // disclosure that starts closed. `max-lg:hidden` is the switch, so from `lg` up
    // the desktop header is always expanded and nothing here changes it.
    render(
      header({
        vocation: { name: "Builder" },
        model: { name: "gpt", provider: "openai" },
      }),
    );

    const toggle = screen.getByRole("button", { name: "Agent details" });
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    // The chevron and the dot live in a phone-only row beside the name.
    expect(toggle.parentElement.className).toContain("lg:hidden");

    const modelChip = screen.getByRole("button", { name: "Change model" });
    expect(modelChip.closest("p").className).toContain("max-lg:hidden");
    expect(screen.getByTestId("usage-chip").className).toContain(
      "max-lg:hidden",
    );
    // The one status signal left on the line is not colour-only: the dot carries
    // the label for a screen reader, and the label text is in the disclosure.
    expect(screen.getByRole("img", { name: "Idle" })).toBeInTheDocument();

    fireEvent.click(toggle);

    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(modelChip.closest("p").className).not.toContain("max-lg:hidden");
    expect(screen.getByTestId("usage-chip").className).not.toContain(
      "max-lg:hidden",
    );
  });

  it("clamps the name to two lines and puts the vocation on its own line below lg", () => {
    // At 390px the heading took three lines for a name like
    // `charming-rhinoceros-root`, and the inline `(Programmer)` was glued to it
    // with no space. Below `lg` the name is clamped to two lines — one ellipsised
    // line is not readable either, since a phone has no tooltip to reveal a
    // 30-character agent name — the vocation is a subtitle, and the token column
    // is the header's full width so its readout wraps instead of pushing the
    // strip sideways. The full name stays in the DOM: clamping is visual.
    render(header({ vocation: { name: "Builder" } }));

    // The clamp is visual: the heading's text — and so its accessible name —
    // still holds the whole name, and there is no `title`, which would be a
    // hover tooltip the desktop never had and a phone cannot use.
    const heading = screen.getByRole("heading", { name: /alpha/ });
    expect(heading.className).toContain("max-lg:line-clamp-2");
    expect(heading).not.toHaveAttribute("title");

    // From `lg` up the vocation rides on the heading, now with the space it was
    // missing; below `lg` it is hidden in favour of the subtitle.
    const inlineVocation = heading.querySelector("span");
    expect(inlineVocation.className).toContain("hidden");
    expect(inlineVocation.className).toContain("lg:inline");
    expect(inlineVocation.textContent.startsWith(" (")).toBe(true);

    const subtitle = screen.getByText("Builder");
    expect(subtitle.className).toContain("lg:hidden");
    expect(screen.getByTestId("usage-chip").parentElement.className).toContain(
      "max-lg:w-full",
    );
  });

  it("renders the name, vocation, model, lineage, and status and opens the model picker", () => {
    const onModelPickerOpen = vi.fn();
    render(
      header({
        vocation: { name: "Builder" },
        model: { name: "gpt", provider: "openai" },
        parentName: "root",
        depth: 2,
        onModelPickerOpen,
        getStatusLabel: () => "Generating response",
      }),
    );

    expect(screen.getByRole("heading", { name: /alpha/ })).toHaveTextContent(
      "(Builder)",
    );
    expect(screen.getByText("openai: gpt")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /back to root/i })).toHaveAttribute(
      "href",
      "/space/my-space/agent/root",
    );
    expect(screen.getByText("(depth 2)")).toBeInTheDocument();
    expect(screen.getByText("Generating response")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Change model" }));
    expect(onModelPickerOpen).toHaveBeenCalledTimes(1);
  });

  it("omits the vocation, lineage, and zero depth and falls back to the bare model name / [missing]", () => {
    const { rerender } = render(header({ model: { name: "solo" } }));

    expect(screen.getByText("solo")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /back to/i })).toBeNull();
    expect(screen.queryByText(/\(depth/)).toBeNull();

    // Parent present but depth is zero → link shown, depth badge omitted.
    rerender(header({ model: { name: "solo" }, parentName: "root", depth: 0 }));
    expect(
      screen.getByRole("link", { name: /back to root/i }),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\(depth/)).toBeNull();

    rerender(header({ model: null }));
    expect(screen.getByText("[missing]")).toBeInTheDocument();
  });

  it("highlights a model_missing agent and renders the change-model error", () => {
    const { rerender } = render(header({ model: { name: "gpt" } }));
    expect(
      screen.getByRole("button", { name: "Change model" }).className,
    ).not.toMatch(/bg-amber-100/);

    rerender(
      header({
        model: { name: "gpt" },
        agentState: "model_missing",
        changeModelError: "could not switch model",
      }),
    );

    expect(
      screen.getByRole("button", { name: "Change model" }).className,
    ).toMatch(/bg-amber-100/);
    expect(screen.getByText("could not switch model")).toBeInTheDocument();
  });
});
