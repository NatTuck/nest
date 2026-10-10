/**
 * Tests for the status-label + edit-error helpers used by the chat UI.
 */
import { describe, it, expect } from "vitest";
import {
  describeCreateError,
  describeEditError,
  getStatusLabel,
} from "./chatErrors.js";

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
    expect(describeEditError("workspace_required")).toMatch(/required/i);
    expect(describeEditError("workspace_missing")).toMatch(/doesn't exist/i);
    expect(describeEditError("workspace_under_tmp")).toMatch(/under \/tmp/i);
  });

  it("falls back to the raw reason, or a generic message when absent", () => {
    expect(describeEditError("weird_reason")).toContain("weird_reason");
    expect(describeEditError(undefined)).toBe("Failed to edit agent.");
  });
});

describe("describeCreateError", () => {
  it("maps every reason a user can act on to a friendly message", () => {
    // The reply is `{reason: <code>}`, never an `Error`.
    expect(describeCreateError({ reason: "workspace_required" })).toMatch(
      /required/i,
    );
    expect(describeCreateError({ reason: "workspace_missing" })).toMatch(
      /doesn't exist/i,
    );
    expect(describeCreateError({ reason: "workspace_under_tmp" })).toMatch(
      /under \/tmp/i,
    );
    expect(describeCreateError({ reason: "blueprint_missing" })).toMatch(
      /blueprint/i,
    );
    expect(describeCreateError({ reason: "vocation_not_found" })).toMatch(
      /vocation/i,
    );
    expect(describeCreateError({ reason: "missing_vocation" })).toMatch(
      /vocation/i,
    );
  });

  it("words the workspace refusals exactly as the edit-agent path does", () => {
    for (const reason of [
      "workspace_required",
      "workspace_missing",
      "workspace_under_tmp",
    ]) {
      expect(describeCreateError({ reason })).toBe(describeEditError(reason));
    }
  });

  it("falls back to the Error message, then to a generic message", () => {
    expect(describeCreateError({ message: "boom" })).toBe("boom");
    expect(describeCreateError({ reason: "failed_to_create" })).toBe(
      "Failed to create space.",
    );
    expect(describeCreateError({})).toBe("Failed to create space.");
    expect(describeCreateError(undefined)).toBe("Failed to create space.");
  });
});
