/**
 * Tests for useDocumentTitle.
 *
 * Covers:
 * - The pure `buildDocumentTitle` builder: host first, parts joined
 *   with " · ", empty/whitespace/null/undefined/non-string parts
 *   dropped, and the host resolved from `window.NEST_CONFIG.host`
 *   (falling back to "[missing host]" when it is absent, empty, or not
 *   a string).
 * - The hook: applies the built title on mount, updates it when the
 *   parts change, and -- crucially -- does not re-run its effect when a
 *   caller passes an equal-but-new segments array (which every page
 *   does on every render).
 *
 * `window.NEST_CONFIG` is set explicitly here rather than read from the
 * environment, and `document.title` is reset between tests so one
 * test's title can never leak into the next.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook } from "@testing-library/react";

import {
  MISSING_HOST,
  TITLE_SEPARATOR,
  buildDocumentTitle,
  useDocumentTitle,
} from "./useDocumentTitle";

/** The title the server-rendered shell ships with, before React runs. */
const LEGACY_TITLE = "Nest · Phoenix Framework";

beforeEach(() => {
  window.NEST_CONFIG = { host: "vampire" };
  document.title = LEGACY_TITLE;
});

afterEach(() => {
  window.NEST_CONFIG = undefined;
  document.title = "";
});

describe("buildDocumentTitle", () => {
  it("puts the host first and joins every part with a middle dot", () => {
    expect(buildDocumentTitle(["My Space", "alpha"], "vampire")).toBe(
      "vampire · My Space · alpha",
    );
    expect(buildDocumentTitle(["Spaces"], "vampire")).toBe("vampire · Spaces");
    // No page-specific parts (the RootGate) leaves just the host.
    expect(buildDocumentTitle([], "vampire")).toBe("vampire");
    expect(TITLE_SEPARATOR).toBe(" · ");
  });

  it("drops parts that would render as nothing and trims the rest", () => {
    expect(
      buildDocumentTitle(
        ["", "  ", null, undefined, 7, "  About  ", "Invites"],
        "vampire",
      ),
    ).toBe("vampire · About · Invites");
    expect(buildDocumentTitle([null, undefined], "vampire")).toBe("vampire");
  });

  it("resolves the host from window.NEST_CONFIG.host by default", () => {
    expect(buildDocumentTitle(["About"])).toBe("vampire · About");

    window.NEST_CONFIG = { host: "  typhon  " };
    expect(buildDocumentTitle(["About"])).toBe("typhon · About");
  });

  it("uses [missing host] when the configured host is absent, empty, or not a string", () => {
    window.NEST_CONFIG = undefined;
    expect(buildDocumentTitle(["About"])).toBe(`${MISSING_HOST} · About`);

    window.NEST_CONFIG = {};
    expect(buildDocumentTitle([])).toBe(MISSING_HOST);

    window.NEST_CONFIG = { host: "" };
    expect(buildDocumentTitle(["About"])).toBe(`${MISSING_HOST} · About`);

    window.NEST_CONFIG = { host: "   " };
    expect(buildDocumentTitle(["About"])).toBe(`${MISSING_HOST} · About`);

    window.NEST_CONFIG = { host: 42 };
    expect(buildDocumentTitle(["About"])).toBe(`${MISSING_HOST} · About`);
  });
});

describe("useDocumentTitle", () => {
  it("applies the built title on mount and updates it when the parts change", () => {
    const { rerender } = renderHook(
      ({ segments }) => useDocumentTitle(segments),
      { initialProps: { segments: [] } },
    );
    // The RootGate's bare host.
    expect(document.title).toBe("vampire");

    rerender({ segments: ["Spaces"] });
    expect(document.title).toBe("vampire · Spaces");

    rerender({ segments: ["My Space", "alpha"] });
    expect(document.title).toBe("vampire · My Space · alpha");
  });

  it("does not rewrite the title when a caller passes an equal-but-new segments array", () => {
    // Callers pass a fresh array literal on every render. Spying on the
    // title setter is the only way to observe that the effect did not
    // re-run: an array dependency would call this once per render.
    const setTitle = vi.fn();
    Object.defineProperty(document, "title", {
      configurable: true,
      get: () => "",
      set: setTitle,
    });

    try {
      const { rerender } = renderHook(
        ({ segments }) => useDocumentTitle(segments),
        { initialProps: { segments: ["Spaces"] } },
      );
      expect(setTitle).toHaveBeenCalledTimes(1);
      expect(setTitle).toHaveBeenLastCalledWith("vampire · Spaces");

      // Equal contents, new array identity -- the effect must not re-run.
      rerender({ segments: ["Spaces"] });
      expect(setTitle).toHaveBeenCalledTimes(1);

      // A genuinely different title does re-run it.
      rerender({ segments: ["About"] });
      expect(setTitle).toHaveBeenCalledTimes(2);
      expect(setTitle).toHaveBeenLastCalledWith("vampire · About");
    } finally {
      // Drop the own accessor so the real Document.prototype.title
      // descriptor (and the rest of the file's assertions) work again.
      delete document.title;
    }
  });

  it("shows [missing host] when the server did not report a host", () => {
    window.NEST_CONFIG = undefined;
    const { rerender } = renderHook(
      ({ segments }) => useDocumentTitle(segments),
      { initialProps: { segments: ["Sign in"] } },
    );
    expect(document.title).toBe(`${MISSING_HOST} · Sign in`);

    window.NEST_CONFIG = { host: 7 };
    rerender({ segments: ["Register"] });
    expect(document.title).toBe(`${MISSING_HOST} · Register`);
  });
});
