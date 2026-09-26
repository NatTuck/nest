/**
 * Tests for `js/components/ChatComposer.jsx`.
 *
 * The composer owns the floating "Jump to latest" button and delegates the
 * input to `ChatInput`. `ChatInput` is mocked so these tests can assert the
 * button's visibility/behaviour and the prop pass-through in isolation.
 */

import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatComposer } from "./ChatComposer";

vi.mock("./ChatInput", () => ({
  ChatInput: ({ value, placeholder, isBusy }) => (
    <div
      data-testid="chat-input"
      data-value={value}
      data-placeholder={placeholder}
      data-busy={String(isBusy)}
    />
  ),
}));

function composer(overrides = {}) {
  const props = {
    inputValue: "",
    onChange: vi.fn(),
    onSend: vi.fn(),
    onStop: vi.fn(),
    isBusy: false,
    stopping: false,
    disabled: false,
    frozen: false,
    placeholder: "Type a message...",
    modes: undefined,
    mode: undefined,
    onModeChange: vi.fn(),
    history: undefined,
    hasNewContent: false,
    isAtBottom: true,
    jumpToBottom: vi.fn(),
    ...overrides,
  };
  return <ChatComposer {...props} />;
}

describe("ChatComposer", () => {
  it("hides the jump button when there is no new content or the view is already at the bottom", () => {
    const { rerender } = render(
      composer({ hasNewContent: false, isAtBottom: false }),
    );
    expect(
      screen.queryByRole("button", { name: /jump to latest/i }),
    ).toBeNull();

    rerender(composer({ hasNewContent: true, isAtBottom: true }));
    expect(
      screen.queryByRole("button", { name: /jump to latest/i }),
    ).toBeNull();
  });

  it("shows the jump button and jumps when new content arrives off the bottom", () => {
    const jumpToBottom = vi.fn();
    render(
      composer({
        hasNewContent: true,
        isAtBottom: false,
        jumpToBottom,
      }),
    );

    fireEvent.click(screen.getByRole("button", { name: /jump to latest/i }));

    expect(jumpToBottom).toHaveBeenCalledTimes(1);
  });

  it("passes the input props through to ChatInput", () => {
    render(
      composer({
        inputValue: "hello",
        placeholder: "Ask anything",
        isBusy: true,
      }),
    );

    const input = screen.getByTestId("chat-input");
    expect(input).toHaveAttribute("data-value", "hello");
    expect(input).toHaveAttribute("data-placeholder", "Ask anything");
    expect(input).toHaveAttribute("data-busy", "true");
  });
});
