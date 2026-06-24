/**
 * `copyToClipboard` and `useCopyToClipboard` tests.
 *
 * jsdom doesn't ship `navigator.clipboard`, so each test
 * installs/removes its own mock. The fallback path is exercised
 * by deleting the clipboard property and providing `document
 * .execCommand`; React's `act` is used around the hook to flush
 * state updates.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { copyToClipboard, useCopyToClipboard } from "./clipboard.js";

describe("copyToClipboard", () => {
  it("uses navigator.clipboard.writeText when available and resolves true on success", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });

    const ok = await copyToClipboard("hello world");

    expect(ok).toBe(true);
    expect(writeText).toHaveBeenCalledWith("hello world");
  });

  it("falls back to a hidden textarea + execCommand when navigator.clipboard is missing", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: undefined,
      configurable: true,
      writable: true,
    });
    const execCommand = vi.fn().mockReturnValue(true);
    document.execCommand = execCommand;

    const ok = await copyToClipboard("legacy path");

    expect(ok).toBe(true);
    expect(execCommand).toHaveBeenCalledWith("copy");
  });

  it("returns false when both the modern and the legacy paths fail", async () => {
    const writeText = vi.fn().mockRejectedValue(new Error("blocked"));
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });
    const execCommand = vi.fn().mockReturnValue(false);
    document.execCommand = execCommand;
    // The clipboard util logs a [NEST REGRESSION] diagnostic on
    // the modern path's failure. Silence it so the test runner
    // doesn't treat the expected error as a test failure.
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const ok = await copyToClipboard("nope");

    expect(ok).toBe(false);
    // The fallback should have been tried after the modern API
    // rejected.
    expect(execCommand).toHaveBeenCalledWith("copy");
    errorSpy.mockRestore();
  });

  it("returns false for non-string input and does not call any clipboard API", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });

    expect(await copyToClipboard(undefined)).toBe(false);
    expect(await copyToClipboard(null)).toBe(false);
    expect(await copyToClipboard(42)).toBe(false);
    expect(writeText).not.toHaveBeenCalled();
  });

  it("catches a synchronous throw from document.execCommand and returns false", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: undefined,
      configurable: true,
      writable: true,
    });
    document.execCommand = vi.fn().mockImplementation(() => {
      throw new Error("execCommand blew up");
    });
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const ok = await copyToClipboard("anything");

    expect(ok).toBe(false);
    errorSpy.mockRestore();
  });
});

describe("useCopyToClipboard", () => {
  beforeEach(() => {
    Object.defineProperty(navigator, "clipboard", {
      value: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
      configurable: true,
      writable: true,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("starts with copied=false and a no-op copy", () => {
    const { result } = renderHook(() => useCopyToClipboard());
    expect(result.current[0]).toBe(false);
    expect(typeof result.current[1]).toBe("function");
  });

  it("flips copied to true on successful copy, then back to false after the timeout", async () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useCopyToClipboard(1000));

    await act(async () => {
      const ok = await result.current[1]("text");
      expect(ok).toBe(true);
    });

    expect(result.current[0]).toBe(true);

    act(() => {
      vi.advanceTimersByTime(1000);
    });
    expect(result.current[0]).toBe(false);
  });

  it("leaves copied=false when the clipboard write fails", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockRejectedValue(new Error("blocked")) },
      configurable: true,
      writable: true,
    });
    document.execCommand = vi.fn().mockReturnValue(false);
    // Same rationale as the `copyToClipboard` failure test —
    // silence the expected [NEST REGRESSION] log.
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const { result } = renderHook(() => useCopyToClipboard());
    await act(async () => {
      const ok = await result.current[1]("text");
      expect(ok).toBe(false);
    });

    expect(result.current[0]).toBe(false);
    errorSpy.mockRestore();
  });

  it("clears the previous revert timer when copy is called twice within the feedback window", async () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useCopyToClipboard(1000));

    await act(async () => {
      await result.current[1]("first");
    });
    expect(result.current[0]).toBe(true);

    // Halfway through the first window, copy again. The new
    // copy should reset the timer — the first window's revert
    // is cleared so the user sees a fresh 1000ms of "Copied".
    await act(async () => {
      vi.advanceTimersByTime(500);
    });
    await act(async () => {
      await result.current[1]("second");
    });
    expect(result.current[0]).toBe(true);

    // 500ms after the second copy (1000ms total) the first
    // window would have fired its revert, but it was cleared.
    // Verify the state is still true.
    act(() => {
      vi.advanceTimersByTime(500);
    });
    expect(result.current[0]).toBe(true);

    // 1000ms after the second copy, the second window fires.
    act(() => {
      vi.advanceTimersByTime(500);
    });
    expect(result.current[0]).toBe(false);
  });
});
