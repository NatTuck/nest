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
    expect(describeCreateError({ reason: "invalid_agent_name" })).toMatch(
      /letters, numbers, dashes and underscores/i,
    );
    expect(describeCreateError({ reason: "scratch_name_in_use" })).toMatch(
      /none/i,
    );
  });

  it("names the other space holding the scratch name", () => {
    const message = describeCreateError({
      reason: "scratch_name_in_use",
      space_name: "quiet-otter",
    });

    expect(message).toContain("quiet-otter");
    // Two `none`-backend spaces share the host /tmp, so their names collide.
    expect(message).toMatch(/\/tmp/);
  });

  it("names the symlinked config file and says how to fix it", () => {
    // A `.nest` or `AGENTS.md` that is a symlink cannot be masked, so the
    // workspace is refused until it is a regular file. The user needs the path
    // and the remedy, not just the refusal.
    const message = describeCreateError({
      reason: "config_file_not_regular",
      path: "/home/nat/proj/AGENTS.md",
    });

    expect(message).toContain("/home/nat/proj/AGENTS.md");
    // Not "is a symlink": the reason fires for a directory, a fifo or an
    // unreadable path too, and the server does not say which.
    expect(message).toMatch(/not a regular file/i);
    expect(message).toMatch(/copy the file into the workspace/i);
  });

  it('does not say "undefined" when the config-file path is missing', () => {
    const message = describeCreateError({ reason: "config_file_not_regular" });

    expect(message).toMatch(/not a regular file/i);
    expect(message).not.toContain("undefined");
  });

  it("names the path when the scratch path is already something else", () => {
    const message = describeCreateError({
      reason: "scratch_path_taken",
      path: "/tmp/X11-unix",
    });

    expect(message).toContain("/tmp/X11-unix");
    // The answer is another name, not a retry.
    expect(message).toMatch(/another agent name/i);
  });

  it("still says something useful when the taken path is missing", () => {
    // The server always sends it, but a message with "undefined" in it would be
    // worse than a vaguer sentence.
    const message = describeCreateError({ reason: "scratch_path_taken" });

    expect(message).toMatch(/scratch path/i);
    expect(message).not.toContain("undefined");
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
