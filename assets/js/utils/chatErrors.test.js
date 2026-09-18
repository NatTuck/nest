/**
 * Tests for the status-label + edit-error helpers used by the chat UI.
 */
import { describe, it, expect } from "vitest";
import { describeEditError, getStatusLabel } from "./chatErrors.js";

describe("getStatusLabel", () => {
  it("returns the raw connection status when not connected", () => {
    expect(getStatusLabel("disconnected", false, false, false, false)).toBe(
      "disconnected",
    );
    expect(getStatusLabel("connecting", false, false, false, false)).toBe(
      "connecting",
    );
  });

  it("labels every connected agent state distinctly", () => {
    // Each row is a distinct combination of the derived flags
    // (streaming, executingTools, waitingForResponse, compacting).
    const cases = [
      [[true, false, false, false], "Generating response"],
      [[false, true, false, false], "Executing tools"],
      [[false, false, true, false], "Waiting for response"],
      [[false, false, false, true], "Compacting conversation…"],
      // Compacting outranks the transient waiting flag.
      [[false, false, true, true], "Compacting conversation…"],
      [[false, false, false, false], "Ready"],
    ];

    for (const [
      [streaming, executingTools, waiting, compacting],
      label,
    ] of cases) {
      expect(
        getStatusLabel(
          "connected",
          streaming,
          executingTools,
          waiting,
          compacting,
        ),
      ).toBe(label);
    }
  });
});

describe("describeEditError", () => {
  it("maps known reasons to friendly messages", () => {
    expect(describeEditError("agent_busy")).toMatch(/busy/i);
    expect(describeEditError("invalid_model")).toMatch(/model/i);
    expect(describeEditError("context_overflow")).toMatch(/compact/i);
    expect(describeEditError("not_found")).toMatch(/not found/i);
    expect(describeEditError("invalid_payload")).toMatch(/try again/i);
  });

  it("falls back to the raw reason, or a generic message when absent", () => {
    expect(describeEditError("weird_reason")).toContain("weird_reason");
    expect(describeEditError(undefined)).toBe("Failed to edit agent.");
  });
});
