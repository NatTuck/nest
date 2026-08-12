/**
 * Tests for `vocationRequiresWorkspace/1`.
 */
import { describe, it, expect } from "vitest";
import { vocationRequiresWorkspace } from "./vocationWorkspace.js";

describe("vocationRequiresWorkspace", () => {
  it("returns false for a vocation with no modes", () => {
    expect(vocationRequiresWorkspace(null)).toBe(false);
    expect(vocationRequiresWorkspace({})).toBe(false);
    expect(vocationRequiresWorkspace({ name: "Chat" })).toBe(false);
  });

  it("returns true when any mode writes to :workspace", () => {
    const vocation = {
      modes: {
        chat: { caps: { fs: { write: ["/tmp", ":workspace"] } } },
      },
    };
    expect(vocationRequiresWorkspace(vocation)).toBe(true);
  });

  it("returns false when no mode writes to :workspace", () => {
    const vocation = {
      modes: {
        chat: { caps: { fs: { write: ["/tmp"] } } },
      },
    };
    expect(vocationRequiresWorkspace(vocation)).toBe(false);
  });

  it("returns false when modes or caps are malformed", () => {
    expect(vocationRequiresWorkspace({ modes: { chat: {} } })).toBe(false);
    expect(vocationRequiresWorkspace({ modes: { chat: { caps: {} } } })).toBe(
      false,
    );
  });
});
