/**
 * ProbeCachePanel component tests.
 *
 * Covers: the stats line and the clear button's label for a known,
 * empty and unreported cache (including each individually missing stat),
 * the age formatting, the stats fetch on mount, the two-step clear and
 * all three of its error paths, and the rescan button the panel hosts.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  waitFor,
  act,
} from "@testing-library/react";

import { ProbeCachePanel } from "./ProbeCachePanel";
import { useStore } from "../store";

vi.mock("../channels", async () => {
  const actual = await vi.importActual("../channels");
  return {
    ...actual,
    clearProbeCache: vi.fn(),
    requestProbeCacheStats: vi.fn(),
  };
});

import { clearProbeCache, requestProbeCacheStats } from "../channels";

const PATH = "/home/nat/.config/nest/probe-cache.json";

const cachedStats = { entries: 12, oldest_age_s: 259200, path: PATH };

function setStats(stats) {
  act(() => {
    useStore.getState().setProbeCacheStats(stats);
  });
}

function renderPanel(props = {}) {
  return render(
    <ProbeCachePanel isRescanning={false} onRescan={() => {}} {...props} />,
  );
}

// Matches the idle label and the armed one alike, so the same helper can
// click the button twice; "Rescan providers" never contains "clear".
const clearButton = () => screen.getByRole("button", { name: /clear/i });

// The clear takes two clicks by design: the first arms it, the second
// destroys. Every test that expects a clear to happen arms it first.
function clickClear() {
  fireEvent.click(clearButton());
  fireEvent.click(clearButton());
}

describe("ProbeCachePanel", () => {
  beforeEach(() => {
    clearProbeCache.mockReset();
    requestProbeCacheStats.mockReset();
    act(() => {
      useStore.getState()._reset();
    });
  });

  afterEach(() => {
    act(() => {
      useStore.getState()._reset();
    });
    vi.clearAllMocks();
  });

  it("fetches its own stats when it appears", () => {
    // The panel is the only reader of the cache's stats, so it asks
    // rather than waiting for a broadcast.
    renderPanel();

    expect(requestProbeCacheStats).toHaveBeenCalledTimes(1);
  });

  it("labels the clear button with the count and the oldest age", () => {
    setStats(cachedStats);

    renderPanel();

    expect(
      screen.getByRole("button", {
        name: "Clear probe cache (12 entries, oldest 3 days)",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(`12 entries · oldest 3 days · ${PATH}`),
    ).toBeInTheDocument();
  });

  it("says the count is not filtered by endpoint", () => {
    // `stats/0` has no provider struct to compare fingerprints against,
    // so it counts every verdict on file — including one the next scan
    // would re-probe. The panel must not present the number as more than
    // that.
    setStats(cachedStats);

    renderPanel();

    expect(
      screen.getByText(/provider endpoint has since changed/i),
    ).toBeInTheDocument();
  });

  it("uses the singular for a one-entry cache", () => {
    setStats({ entries: 1, oldest_age_s: 5, path: "/tmp/probe-cache.json" });

    renderPanel();

    expect(
      screen.getByRole("button", {
        name: "Clear probe cache (1 entry, oldest 5 s)",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("1 entry · oldest 5 s · /tmp/probe-cache.json"),
    ).toBeInTheDocument();
  });

  it("reports an age in the largest whole unit that still reads as a number", () => {
    const cases = [
      [0, "oldest 0 s"],
      [59, "oldest 59 s"],
      [60, "oldest 1 min"],
      [3599, "oldest 59 min"],
      [3600, "oldest 1 h"],
      [86399, "oldest 23 h"],
      [86400, "oldest 1 day"],
      [259200, "oldest 3 days"],
    ];

    for (const [oldest_age_s, expected] of cases) {
      setStats({ entries: 2, oldest_age_s, path: "/tmp/probe-cache.json" });
      const { unmount } = renderPanel();

      // Anchored on the summary line's path so the match cannot land on
      // the clear button, which carries the same age.
      expect(
        screen.getByText(new RegExp(`${expected} · /tmp/probe-cache.json`)),
      ).toBeInTheDocument();

      unmount();
    }
  });

  it("distinguishes an empty cache from one the lobby has not reported", () => {
    setStats({ entries: 0, oldest_age_s: null, path: PATH });
    const empty = renderPanel();

    expect(
      screen.getByRole("button", { name: "Clear probe cache (empty)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(`no cached verdicts · ${PATH}`),
    ).toBeInTheDocument();

    // Arming it keeps the same claim, so the second click still says
    // "empty" rather than falling back to the unknown wording.
    fireEvent.click(clearButton());
    expect(
      screen.getByRole("button", { name: "Click again to clear (empty)" }),
    ).toBeInTheDocument();
    empty.unmount();

    // Nothing reported: an explicit unknown, never an empty cache —
    // "nothing is cached" would be a claim we cannot make.
    setStats(null);
    renderPanel();

    expect(
      screen.getByRole("button", { name: "Clear probe cache (state unknown)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/cache state unknown — the lobby has not reported it/i),
    ).toBeInTheDocument();

    fireEvent.click(clearButton());
    expect(
      screen.getByRole("button", {
        name: "Click again to clear (state unknown)",
      }),
    ).toBeInTheDocument();
  });

  it("names each missing stat instead of rendering nothing", () => {
    setStats({ entries: 4, path: null });
    const noPath = renderPanel();

    expect(
      screen.getByRole("button", {
        name: "Clear probe cache (4 entries, oldest age unknown)",
      }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        "4 entries · oldest age unknown · cache file path unknown",
      ),
    ).toBeInTheDocument();
    noPath.unmount();

    // A count we were not given is unknown, not zero.
    setStats({ path: "/tmp/probe-cache.json" });
    renderPanel();

    expect(
      screen.getByRole("button", { name: "Clear probe cache (state unknown)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText("entry count unknown · /tmp/probe-cache.json"),
    ).toBeInTheDocument();
  });

  it("arms the clear on the first click and only clears on the second", async () => {
    setStats(cachedStats);
    clearProbeCache.mockImplementation((onOk) => onOk());

    renderPanel();

    fireEvent.click(clearButton());

    // The first click is reversible: it only relabels the button.
    expect(clearProbeCache).not.toHaveBeenCalled();
    expect(
      screen.getByRole("button", { name: "Click again to clear (12 entries)" }),
    ).toBeInTheDocument();

    fireEvent.click(clearButton());

    await waitFor(() => expect(clearProbeCache).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(clearButton()).toBeEnabled());
  });

  it("disarms the armed clear when the button loses focus", () => {
    setStats(cachedStats);

    renderPanel();

    fireEvent.click(clearButton());
    expect(
      screen.getByRole("button", { name: /click again to clear/i }),
    ).toBeInTheDocument();

    fireEvent.blur(clearButton());

    expect(
      screen.getByRole("button", {
        name: "Clear probe cache (12 entries, oldest 3 days)",
      }),
    ).toBeInTheDocument();
    expect(clearProbeCache).not.toHaveBeenCalled();
  });

  it("clears the cache through the lobby and re-enables the button", async () => {
    setStats(cachedStats);
    clearProbeCache.mockImplementation((onOk) => onOk());

    renderPanel();

    clickClear();

    await waitFor(() => expect(clearProbeCache).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(clearButton()).toBeEnabled());
  });

  it("shows a busy label while the clear is in flight", async () => {
    setStats(cachedStats);
    let resolveOk;
    clearProbeCache.mockImplementation((onOk) => {
      resolveOk = onOk;
    });

    renderPanel();

    clickClear();

    await waitFor(() =>
      expect(screen.getByText("Clearing…")).toBeInTheDocument(),
    );
    expect(screen.getByRole("button", { name: "Clearing…" })).toBeDisabled();

    act(() => resolveOk());

    await waitFor(() => expect(clearButton()).toBeEnabled());
  });

  it("surfaces a server-provided reason when the clear fails", async () => {
    setStats(cachedStats);
    clearProbeCache.mockImplementation((_onOk, onError) =>
      onError({ reason: "forbidden" }),
    );

    renderPanel();

    clickClear();

    await waitFor(() =>
      expect(screen.getByText("forbidden")).toBeInTheDocument(),
    );
    expect(clearButton()).toBeEnabled();
  });

  it("surfaces the transport message when the clear fails without a server reason", async () => {
    setStats(cachedStats);
    clearProbeCache.mockImplementation((_onOk, onError) =>
      onError(new Error("Not connected to lobby")),
    );

    renderPanel();

    clickClear();

    await waitFor(() =>
      expect(screen.getByText("Not connected to lobby")).toBeInTheDocument(),
    );
  });

  it("falls back to a sentence when the error carries neither message nor reason", async () => {
    setStats(cachedStats);
    clearProbeCache.mockImplementation((_onOk, onError) => onError({}));

    renderPanel();

    clickClear();

    await waitFor(() =>
      expect(
        screen.getByText(/failed to clear the probe cache/i),
      ).toBeInTheDocument(),
    );
  });

  it("hosts the rescan button beside the clear button", () => {
    const onRescan = vi.fn();

    renderPanel({ onRescan });

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    expect(onRescan).toHaveBeenCalledTimes(1);
    expect(clearButton()).toBeInTheDocument();
  });

  it("disables the rescan button while a rescan is in flight", () => {
    renderPanel({ isRescanning: true });

    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toBeDisabled();
  });
});
