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
});
