/**
 * Tests for `js/api/invites.js`.
 *
 * Covers: list/create/revoke hitting the correct endpoints with the
 * correct methods and paths.
 */

import { describe, it, beforeEach, afterEach, vi } from "vitest";
import assert from "node:assert";
import { listInvites, createInvite, revokeInvite } from "./invites";

describe("api/invites", () => {
  let originalFetch;

  beforeEach(() => {
    originalFetch = global.fetch;
    localStorage.clear();
  });

  afterEach(() => {
    global.fetch = originalFetch;
    localStorage.clear();
  });

  function mockJson(status, body) {
    global.fetch = vi.fn(() =>
      Promise.resolve({
        ok: status >= 200 && status < 300,
        status,
        text: () => Promise.resolve(JSON.stringify(body)),
      }),
    );
  }

  it("listInvites issues GET /api/v1/invites", async () => {
    mockJson(200, { invites: [] });

    const result = await listInvites();

    const [path, opts] = global.fetch.mock.calls[0];
    assert.strictEqual(path, "/api/v1/invites");
    assert.strictEqual(opts.method, "GET");
    assert.deepStrictEqual(result, { invites: [] });
  });

  it("createInvite issues POST /api/v1/invites", async () => {
    mockJson(201, {
      id: 1,
      token: "secret",
      expires_at: "2026-12-31T00:00:00Z",
    });

    const result = await createInvite();

    const [path, opts] = global.fetch.mock.calls[0];
    assert.strictEqual(path, "/api/v1/invites");
    assert.strictEqual(opts.method, "POST");
    assert.strictEqual(result.token, "secret");
  });

  it("revokeInvite issues DELETE /api/v1/invites/:id", async () => {
    mockJson(204, {});

    await revokeInvite(42);

    const [path, opts] = global.fetch.mock.calls[0];
    assert.strictEqual(path, "/api/v1/invites/42");
    assert.strictEqual(opts.method, "DELETE");
  });
});
