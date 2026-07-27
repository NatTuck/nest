/**
 * CopyButton component tests.
 *
 * Covers the icon/label states (copy icon + default label by
 * default, check icon + "Copied" label after a click, reverts
 * after the feedback window) and the actual clipboard write
 * (the `getText` callback is invoked on click and the returned
 * string is passed to `navigator.clipboard.writeText`).
 *
 * The lazy-resolution contract is the critical perf invariant:
 * `getText` MUST NOT be called during render. Most copy buttons
 * are never clicked, so materializing the text eagerly would
 * be wasted work at every render.
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
    render(<CopyButton getText={() => "hello"} label="Copy greeting" />);
    expect(
      screen.getByRole("button", { name: /copy greeting/i }),
    ).toBeInTheDocument();
  });

  it("defaults the label to 'Copy' when none is provided", () => {
    render(<CopyButton getText={() => "hello"} />);
    expect(screen.getByRole("button", { name: /^copy$/i })).toBeInTheDocument();
  });

  it("writes the supplied text to the clipboard when clicked", async () => {
    const getText = vi.fn(() => "the markdown body");
    render(<CopyButton getText={getText} label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /copy/i }));
    });
    expect(getText).toHaveBeenCalledTimes(1);
    expect(writeText).toHaveBeenCalledWith("the markdown body");
  });

  it("flips the label to 'Copied' after a successful click and reverts after the feedback window", async () => {
    vi.useFakeTimers();
    render(<CopyButton getText={() => "x"} label="Copy" feedbackMs={500} />);

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

    render(<CopyButton getText={() => "x"} label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^copy$/i }));
    });

    expect(
      screen.queryByRole("button", { name: /copied/i }),
    ).not.toBeInTheDocument();
    errorSpy.mockRestore();
  });
});

describe("CopyButton lazy resolution", () => {
  // The lazy contract: `getText` must not be called during render.
  // Most copy buttons are never clicked, so the heavy work (markdown
  // join, JSON.stringify of large API-log payloads) only happens on
  // the click. This is the single biggest perf win at high message
  // counts.
  beforeEach(() => {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
      configurable: true,
      writable: true,
    });
  });

  it("does not call getText during render", () => {
    const getText = vi.fn(() => "hello");
    render(<CopyButton getText={getText} label="Copy" />);
    expect(getText).not.toHaveBeenCalled();
  });

  it("does not crash when getText throws and logs a [NEST REGRESSION] error", async () => {
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const getText = vi.fn(() => {
      throw new Error("synthetic boom");
    });

    render(<CopyButton getText={getText} label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^copy$/i }));
    });

    expect(getText).toHaveBeenCalledTimes(1);
    expect(errorSpy).toHaveBeenCalledWith(
      "[NEST REGRESSION] CopyButton getText threw",
      expect.any(Error),
    );
    // The button must remain in its initial copy state (no "Copied"
    // feedback) since the click was a no-op.
    expect(
      screen.queryByRole("button", { name: /copied/i }),
    ).not.toBeInTheDocument();
    errorSpy.mockRestore();
  });

  it("does not call writeText when getText returns a non-string", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });
    const getText = vi.fn(() => null);

    render(<CopyButton getText={getText} label="Copy" />);
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /^copy$/i }));
    });

    expect(getText).toHaveBeenCalledTimes(1);
    expect(writeText).not.toHaveBeenCalled();
    expect(
      screen.queryByRole("button", { name: /copied/i }),
    ).not.toBeInTheDocument();
  });
});
