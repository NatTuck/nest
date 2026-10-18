/**
 * Tests for `useAgentMode` — the composer's mode **draft**.
 *
 * The draft is what the next message asks for; it is not a server setting. Two
 * behaviours matter and are pinned here: the server's mode seeds the draft only
 * when it actually *moves* (so a selection in progress is not overwritten by
 * every `chat:status` frame), and a draft belongs to one agent — switching
 * agents starts a fresh one, even when both agents report the same mode.
 */
import { describe, it, expect } from "vitest";
import { act, renderHook } from "@testing-library/react";

import { useAgentMode } from "./useAgentMode";

function renderDraft(props) {
  return renderHook((p) => useAgentMode(p), { initialProps: props });
}

describe("useAgentMode", () => {
  it("seeds the draft from the server's mode", () => {
    const { result } = renderDraft({
      name: "alpha",
      currentModeFromCache: "plan",
      defaultMode: "act",
    });

    expect(result.current.currentMode).toBe("plan");
  });

  it("falls back to the default mode before the first status frame", () => {
    const { result } = renderDraft({
      name: "alpha",
      currentModeFromCache: null,
      defaultMode: "plan",
    });

    expect(result.current.currentMode).toBe("plan");
  });

  it("keeps a draft the user chose while the server's mode stays put", () => {
    const { result, rerender } = renderDraft({
      name: "alpha",
      currentModeFromCache: "act",
      defaultMode: "act",
    });

    act(() => result.current.handleModeChange("plan"));

    // A repeated status frame is the same value: the draft survives it.
    rerender({
      name: "alpha",
      currentModeFromCache: "act",
      defaultMode: "act",
    });

    expect(result.current.currentMode).toBe("plan");
  });

  it("re-seeds when the server's mode actually moves", () => {
    const { result, rerender } = renderDraft({
      name: "alpha",
      currentModeFromCache: "act",
      defaultMode: "act",
    });

    rerender({
      name: "alpha",
      currentModeFromCache: "plan",
      defaultMode: "act",
    });

    expect(result.current.currentMode).toBe("plan");
  });

  it("starts a fresh draft when the agent changes, even at the same mode", () => {
    // The route component is reused across agents, so this is a re-render, not
    // a remount — and the two agents report the same mode, which is exactly the
    // case the "only when the value moves" rule cannot catch.
    const { result, rerender } = renderDraft({
      name: "alpha",
      currentModeFromCache: "act",
      defaultMode: "act",
    });

    act(() => result.current.handleModeChange("plan"));
    expect(result.current.currentMode).toBe("plan");

    rerender({ name: "beta", currentModeFromCache: "act", defaultMode: "act" });

    expect(result.current.currentMode).toBe("act");
  });

  it("has no draft for the new agent when its mode is not known yet", () => {
    // Null means "the message asks for nothing", which leaves the server's own
    // mode in force. Carrying the previous agent's choice over would be a real
    // request about a different agent.
    const { result, rerender } = renderDraft({
      name: "alpha",
      currentModeFromCache: "act",
      defaultMode: "act",
    });

    rerender({ name: "beta", currentModeFromCache: null, defaultMode: null });

    expect(result.current.currentMode).toBe(null);
  });
});
