/**
 * CopyButton component tests.
 *
 * Covers the icon/label states (copy icon + default label by
 * default, check icon + "Copied" label after a click, reverts
 * after the feedback window) and the actual clipboard write
 * (the right `text` is passed to `navigator.clipboard.writeText`).
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { CopyButton } from "./CopyButton";

describe("CopyButton", () => {
  let writeText;

  beforeEach(() => {
    writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders the copy button with the supplied label", () => {
    render(<CopyButton text="hello" label="Copy greeting" />);
    expect(
      screen.getByRole("button", { name: /copy greeting/i }),
    ).toBeInTheDocument();
  });

  it("defaults the label to 'Copy' when none is provided", () => {
    render(<CopyButton text="hello" />);
    expect(screen.getByRole("button", { name: /^copy$/i })).toBeInTheDocument();
  });

  it("writes the supplied text to the clipboard when clicked", async () => {
    render(<CopyButton text="the markdown body" label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /copy/i }));
    });
    expect(writeText).toHaveBeenCalledWith("the markdown body");
  });

  it("flips the label to 'Copied' after a successful click and reverts after the feedback window", async () => {
    vi.useFakeTimers();
    render(<CopyButton text="x" label="Copy" feedbackMs={500} />);

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^copy$/i }));
    });

    expect(screen.getByRole("button", { name: /copied/i })).toBeInTheDocument();

    await act(async () => {
      vi.advanceTimersByTime(500);
    });
    expect(screen.getByRole("button", { name: /^copy$/i })).toBeInTheDocument();
  });

  it("does not flip to 'Copied' when the clipboard write fails", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockRejectedValue(new Error("blocked")) },
      configurable: true,
      writable: true,
    });
    document.execCommand = vi.fn().mockReturnValue(false);
    // Silence the expected [NEST REGRESSION] log from the
    // clipboard util so the test runner doesn't flag it.
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    render(<CopyButton text="x" label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^copy$/i }));
    });

    expect(
      screen.queryByRole("button", { name: /copied/i }),
    ).not.toBeInTheDocument();
    errorSpy.mockRestore();
  });
});
