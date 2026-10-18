/**
 * Tests for `errorText`, the shared wording for a failed push.
 */

import { describe, it, expect } from "vitest";

import { errorText } from "./errorText";

describe("errorText", () => {
  it("prefers the message, then the reason, then the caller's sentence", () => {
    expect(errorText(new Error("Not connected to lobby"), "fallback")).toBe(
      "Not connected to lobby",
    );
    expect(
      errorText({ message: "boom", reason: "forbidden" }, "fallback"),
    ).toBe("boom");
    expect(errorText({ reason: "forbidden" }, "fallback")).toBe("forbidden");
    expect(errorText({}, "fallback")).toBe("fallback");
    expect(errorText(undefined, "fallback")).toBe("fallback");
  });

  it("names the config file a refusal is about, even with no message", () => {
    // The one reason a bare enum is useless: the user needs the path, and the
    // sentence depends on the `type`. Shared with the create/edit paths, so
    // all three word it identically.
    expect(
      errorText(
        {
          reason: "config_file_not_regular",
          path: "/ws/AGENTS.md",
          type: "hardlink",
        },
        "fallback",
      ),
    ).toMatch(/^\/ws\/AGENTS\.md has more than one name on disk/);
  });
});
