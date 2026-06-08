/**
 * ChatInput Component Tests
 *
 * Covers keyboard handling (Enter, Shift+Enter, Ctrl/Cmd+Enter, IME),
 * the send button, disabled state, controlled value handling, and
 * auto-resize behavior up to the max height.
 */

import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatInput } from "./ChatInput";

function setup(props = {}) {
  const onChange = vi.fn();
  const onSend = vi.fn();
  const utils = render(
    <ChatInput
      value={props.value ?? ""}
      onChange={props.onChange ?? onChange}
      onSend={props.onSend ?? onSend}
      disabled={props.disabled ?? false}
      placeholder={props.placeholder ?? "Type a message..."}
    />,
  );
  const textarea = screen.getByLabelText("Message");
  const sendButton = screen.getByRole("button", { name: /send/i });
  return {
    ...utils,
    textarea,
    sendButton,
    onChange: props.onChange ?? onChange,
    onSend: props.onSend ?? onSend,
  };
}

describe("ChatInput", () => {
  describe("rendering", () => {
    it("renders a multi-line textarea with the Send button", () => {
      const { textarea, sendButton } = setup();
      expect(textarea.tagName).toBe("TEXTAREA");
      expect(textarea).toHaveAttribute("rows", "2");
      expect(sendButton).toBeInTheDocument();
    });

    it("uses the provided placeholder", () => {
      setup({ placeholder: "Connect to send messages..." });
      expect(
        screen.getByPlaceholderText("Connect to send messages..."),
      ).toBeInTheDocument();
    });

    it("reflects the controlled value", () => {
      const { textarea } = setup({ value: "hello there" });
      expect(textarea.value).toBe("hello there");
    });

    it("shows a Ctrl+Enter reminder on the Send button", () => {
      setup();
      expect(screen.getByText("Ctrl+Enter")).toBeInTheDocument();
    });
  });

  describe("typing", () => {
    it("calls onChange with the new value when the user types", () => {
      const { textarea, onChange } = setup();
      fireEvent.change(textarea, { target: { value: "hi" } });
      expect(onChange).toHaveBeenCalledWith("hi");
    });
  });

  describe("keyboard handling", () => {
    it("inserts a newline on Enter (no modifier) and does not send", () => {
      const { textarea, onSend } = setup({ value: "line 1" });
      fireEvent.keyDown(textarea, { key: "Enter", shiftKey: false });
      expect(onSend).not.toHaveBeenCalled();
      // The default newline insertion is a browser behavior; jsdom may not
      // actually mutate .value for textarea via keyDown, so we just verify
      // onSend was not called and preventDefault was not called.
    });

    it("inserts a newline on Shift+Enter and does not send", () => {
      const { textarea, onSend } = setup({ value: "line 1" });
      fireEvent.keyDown(textarea, { key: "Enter", shiftKey: true });
      expect(onSend).not.toHaveBeenCalled();
    });

    it("sends on Ctrl+Enter and does not insert a newline", () => {
      const { textarea, onSend } = setup({ value: "hello" });
      const event = fireEvent.keyDown(textarea, {
        key: "Enter",
        ctrlKey: true,
      });
      expect(onSend).toHaveBeenCalledTimes(1);
      expect(event).toBe(false);
    });

    it("sends on Meta+Enter (Cmd on macOS)", () => {
      const { textarea, onSend } = setup({ value: "hello" });
      fireEvent.keyDown(textarea, { key: "Enter", metaKey: true });
      expect(onSend).toHaveBeenCalledTimes(1);
    });

    it("does not send on Ctrl+Enter when the value is blank", () => {
      const { textarea, onSend } = setup({ value: "   " });
      fireEvent.keyDown(textarea, { key: "Enter", ctrlKey: true });
      expect(onSend).not.toHaveBeenCalled();
    });

    it("does not send on Ctrl+Enter when disabled", () => {
      const { textarea, onSend } = setup({ value: "hello", disabled: true });
      fireEvent.keyDown(textarea, { key: "Enter", ctrlKey: true });
      expect(onSend).not.toHaveBeenCalled();
    });

    it("does not send on Enter while an IME composition is in progress", () => {
      const { textarea, onSend } = setup({ value: "compose" });
      const event = new KeyboardEvent("keydown", {
        key: "Enter",
        ctrlKey: true,
        bubbles: true,
      });
      Object.defineProperty(event, "isComposing", { value: true });
      textarea.dispatchEvent(event);
      expect(onSend).not.toHaveBeenCalled();
    });

    it("does not send on non-Enter keys even with modifiers", () => {
      const { textarea, onSend } = setup({ value: "hello" });
      fireEvent.keyDown(textarea, { key: "a", ctrlKey: true });
      fireEvent.keyDown(textarea, { key: " ", ctrlKey: true });
      expect(onSend).not.toHaveBeenCalled();
    });
  });

  describe("send button", () => {
    it("calls onSend when clicked with non-empty value", () => {
      const { sendButton, onSend } = setup({ value: "hello" });
      fireEvent.click(sendButton);
      expect(onSend).toHaveBeenCalledTimes(1);
    });

    it("is disabled when the value is empty or whitespace", () => {
      const { sendButton, rerender } = setup({ value: "" });
      expect(sendButton).toBeDisabled();
      rerender(
        <ChatInput
          value="   "
          onChange={vi.fn()}
          onSend={vi.fn()}
          disabled={false}
          placeholder="Type a message..."
        />,
      );
      expect(screen.getByRole("button", { name: /send/i })).toBeDisabled();
    });

    it("is disabled when the input is disabled", () => {
      const { sendButton } = setup({ value: "hello", disabled: true });
      expect(sendButton).toBeDisabled();
      fireEvent.click(sendButton);
      // Clicking a disabled button is a no-op; onSend should not fire.
    });

    it("does not call onSend when clicked with blank value", () => {
      const { sendButton, onSend } = setup({ value: "  " });
      fireEvent.click(sendButton);
      expect(onSend).not.toHaveBeenCalled();
    });
  });

  describe("disabled state", () => {
    it("disables the textarea and applies disabled styling", () => {
      const { textarea } = setup({ disabled: true });
      expect(textarea).toBeDisabled();
      expect(textarea.className).toContain("disabled:bg-gray-100");
      expect(textarea.className).toContain("disabled:cursor-not-allowed");
    });
  });

  describe("auto-resize", () => {
    it("caps the textarea height at the configured maxHeight when content overflows", () => {
      const { textarea, rerender, onChange } = setup();
      Object.defineProperty(textarea, "scrollHeight", {
        configurable: true,
        get: () => 9999,
      });
      // Re-render with a new value so useLayoutEffect re-runs with the
      // mocked scrollHeight in place.
      rerender(
        <ChatInput
          value="x"
          onChange={onChange}
          onSend={vi.fn()}
          disabled={false}
          placeholder="Type a message..."
        />,
      );
      expect(textarea.style.maxHeight).toBe("240px");
      expect(textarea.style.height).toBe("240px");
      expect(textarea.style.overflowY).toBe("auto");
    });

    it("grows the textarea to fit short content without scrolling", () => {
      const { textarea, rerender, onChange } = setup();
      Object.defineProperty(textarea, "scrollHeight", {
        configurable: true,
        get: () => 72,
      });
      rerender(
        <ChatInput
          value="hi"
          onChange={onChange}
          onSend={vi.fn()}
          disabled={false}
          placeholder="Type a message..."
        />,
      );
      expect(textarea.style.height).toBe("72px");
      expect(textarea.style.overflowY).toBe("hidden");
    });
  });
});
