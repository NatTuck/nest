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
  TokenUsageChip: () => <div data-testid="usage-chip" />,
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
