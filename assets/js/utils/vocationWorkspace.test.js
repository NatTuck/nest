/**
 * Tests for `vocationRequiresWorkspace/1`.
 *
 * It is a constant now: every space has a workspace, because the `act` mode —
 * which every agent can be in — is what writes it.
 */
import { describe, it, expect } from "vitest";
import { vocationRequiresWorkspace } from "./vocationWorkspace.js";

describe("vocationRequiresWorkspace", () => {
  it("is true whatever it is given", () => {
    for (const vocation of [
      null,
      undefined,
      {},
      { name: "Chat" },
      { modes: {} },
      { modes: { chat: {} } },
      { modes: { chat: { caps: {} } } },
      { modes: { chat: { caps: { fs: { write: ["/tmp"] } } } } },
      { modes: { build: { caps: { fs: { write: ["/tmp", ":workspace"] } } } } },
    ]) {
      expect(vocationRequiresWorkspace(vocation)).toBe(true);
    }
  });

  it("no longer reads the vocation's modes, because there are none", () => {
    // The old rule was "iff some mode writes :workspace". A vocation carrying
    // the old shape must not change the answer either way.
    expect(
      vocationRequiresWorkspace({
        modes: { plan: { caps: { fs: { write: ["/tmp"] } } } },
      }),
    ).toBe(true);
  });
});
