/**
 * Tests for the status-label + edit-error helpers used by the chat UI.
 */
import { describe, it, expect } from "vitest";
import {
  describeCreateError,
  describeEditError,
  describeSpaceEditError,
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
    expect(describeEditError({ reason: "agent_busy" })).toMatch(/busy/i);
    expect(describeEditError({ reason: "invalid_model" })).toMatch(/model/i);
    expect(describeEditError({ reason: "context_overflow" })).toMatch(
      /compact/i,
    );
    expect(describeEditError({ reason: "not_found" })).toMatch(/not found/i);
    expect(describeEditError({ reason: "invalid_payload" })).toMatch(
      /try again/i,
    );
    expect(describeEditError({ reason: "workspace_required" })).toMatch(
      /required/i,
    );
    expect(describeEditError({ reason: "workspace_missing" })).toMatch(
      /doesn't exist/i,
    );
    expect(describeEditError({ reason: "workspace_under_tmp" })).toMatch(
      /under \/tmp/i,
    );
  });

  it("names the non-regular config file, with or without the path", () => {
    // The edit path needs `err.path` too: the server refuses the workspace and
    // says which file, so the message must not drop it.
    const withPath = describeEditError({
      reason: "config_file_not_regular",
      path: "/home/nat/proj/.nest",
    });

    expect(withPath).toContain("/home/nat/proj/.nest");
    expect(withPath).toMatch(/not a regular file/i);
    expect(withPath).toMatch(/copy the file into the workspace/i);

    const withoutPath = describeEditError({
      reason: "config_file_not_regular",
    });

    // The server always sends it, but "undefined" in a message would be worse
    // than the vaguer sentence.
    expect(withoutPath).toMatch(/\.nest/);
    expect(withoutPath).toMatch(/AGENTS\.md/);
    expect(withoutPath).toMatch(/not a regular file/i);
    expect(withoutPath).not.toContain("undefined");
  });

  it("gives a hardlink its own sentence, because a hardlink is a regular file", () => {
    // The one type the generic sentence would be false about. Its remedy is
    // also different: copying over a file with two names leaves both, so the
    // other name has to go.
    const withPath = describeEditError({
      reason: "config_file_not_regular",
      path: "/home/nat/proj/AGENTS.md",
      type: "hardlink",
    });

    expect(withPath).toContain("/home/nat/proj/AGENTS.md");
    expect(withPath).toMatch(/more than one name on disk/i);
    expect(withPath).toMatch(/remove the other name/i);
    expect(withPath).not.toMatch(/is not a regular file/i);
    expect(withPath).not.toContain("undefined");

    const withoutPath = describeEditError({
      reason: "config_file_not_regular",
      type: "hardlink",
    });

    expect(withoutPath).toMatch(/more than one name on disk/i);
    expect(withoutPath).toMatch(/remove the other name/i);
    expect(withoutPath).not.toMatch(/is not a regular file/i);
    expect(withoutPath).not.toContain("undefined");
  });

  it("keeps the generic sentence for every type that is not a hardlink", () => {
    // A `symlink`, a `directory` and an absent `type` are all "not a regular
    // file", and the message must not name a type it was not told.
    for (const err of [
      {
        reason: "config_file_not_regular",
        path: "/ws/.nest",
        type: "symlink",
      },
      {
        reason: "config_file_not_regular",
        path: "/ws/.nest",
        type: "directory",
      },
      { reason: "config_file_not_regular", path: "/ws/.nest" },
    ]) {
      const message = describeEditError(err);

      expect(message).toContain("/ws/.nest");
      expect(message).toMatch(/not a regular file/i);
      expect(message).not.toMatch(/more than one name/i);
    }
  });

  it("falls back to the raw reason, or a generic message when absent", () => {
    expect(describeEditError({ reason: "weird_reason" })).toContain(
      "weird_reason",
    );
    expect(describeEditError(undefined)).toBe("Failed to edit agent.");
  });
});

describe("describeSpaceEditError", () => {
  it("words the shared refusals exactly as the other two paths do", () => {
    // The workspace and config-file refusals are the same facts on every path,
    // so the sentences come from the same helpers.
    for (const reason of [
      "workspace_required",
      "workspace_missing",
      "workspace_under_tmp",
    ]) {
      expect(describeSpaceEditError({ reason })).toBe(
        describeCreateError({ reason }),
      );
    }

    const configFile = {
      reason: "config_file_not_regular",
      path: "/home/nat/ws/.nest",
      type: "symlink",
    };
    expect(describeSpaceEditError(configFile)).toBe(
      describeCreateError(configFile),
    );
  });

  it("names a backend this server does not implement", () => {
    expect(
      describeSpaceEditError({ reason: "invalid_sandbox_backend" }),
    ).toMatch(/sandbox backend isn't one this server implements/);
  });

  it("says the space is gone rather than the agent", () => {
    expect(describeSpaceEditError({ reason: "not_found" })).toMatch(
      /Space not found/,
    );
    expect(describeSpaceEditError({ reason: "invalid_payload" })).toMatch(
      /Couldn't read the edit/,
    );
  });

  it("explains a second session editing the space", () => {
    // `:space_changing` is another session's edit holding the latch — a real
    // state the user can act on (wait), not a failure to report raw.
    expect(describeSpaceEditError({ reason: "space_changing" })).toBe(
      "Another session is editing this space — possibly this one, if the page reconnected. Try again once that edit finishes.",
    );
  });

  it("falls back to the raw reason, then to a generic message", () => {
    expect(describeSpaceEditError({ reason: "failed_to_edit" })).toBe(
      "Failed to save the space: failed_to_edit",
    );
    expect(describeSpaceEditError(undefined)).toBe("Failed to save the space.");
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

  it("words the shared refusals exactly as the edit-agent path does", () => {
    // The workspace refusals and the non-regular config-file refusal each come
    // from one helper both paths call, so their wording cannot drift apart.
    for (const reason of [
      "workspace_required",
      "workspace_missing",
      "workspace_under_tmp",
      "config_file_not_regular",
    ]) {
      expect(describeCreateError({ reason })).toBe(
        describeEditError({ reason }),
      );
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
