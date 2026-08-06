/**
 * Tests for `js/api/client.js`.
 *
 * Covers: token storage round-trip, Bearer header injection, JSON
 * request body serialization, ApiError construction from server
 * error responses, and the `localStorage`-disabled catch paths.
 */

import { describe, it, beforeEach, afterEach, vi } from "vitest";
import assert from "node:assert";
import {
  TOKEN_STORAGE_KEY,
  getStoredToken,
  setStoredToken,
  clearStoredToken,
  ApiError,
  apiFetch,
} from "./client";

describe("api/client — token storage", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    localStorage.clear();
  });

  it("getStoredToken returns null when nothing is stored", () => {
    assert.strictEqual(getStoredToken(), null);
  });

  it("setStoredToken + getStoredToken round-trips a value", () => {
    setStoredToken("abc-123");
    assert.strictEqual(getStoredToken(), "abc-123");
  });

  it("setStoredToken uses the documented localStorage key", () => {
    setStoredToken("xyz");
    assert.strictEqual(localStorage.getItem(TOKEN_STORAGE_KEY), "xyz");
  });

  it("clearStoredToken removes a previously stored value", () => {
    setStoredToken("to-clear");
    clearStoredToken();
    assert.strictEqual(getStoredToken(), null);
  });

  it("getStoredToken returns null when localStorage throws", () => {
    const original = Storage.prototype.getItem;
    Storage.prototype.getItem = vi.fn(() => {
      throw new Error("SecurityError: storage disabled");
    });

    try {
      assert.strictEqual(getStoredToken(), null);
    } finally {
      Storage.prototype.getItem = original;
    }
  });

  it("setStoredToken swallows errors when localStorage throws", () => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = vi.fn(() => {
      throw new Error("QuotaExceededError");
    });

    try {
      // Should not throw.
      setStoredToken("anything");
    } finally {
      Storage.prototype.setItem = original;
    }
  });

  it("clearStoredToken swallows errors when localStorage throws", () => {
    const original = Storage.prototype.removeItem;
    Storage.prototype.removeItem = vi.fn(() => {
      throw new Error("SecurityError");
    });

    try {
      // Should not throw.
      clearStoredToken();
    } finally {
      Storage.prototype.removeItem = original;
    }
  });
});

describe("api/client — ApiError", () => {
  it("uses the server-provided error message when body.error is present", () => {
    const err = new ApiError(400, { error: "bad username" });
    assert.strictEqual(err.status, 400);
    assert.strictEqual(err.message, "bad username");
    assert.deepStrictEqual(err.body, { error: "bad username" });
    assert.ok(err instanceof Error);
  });

  it("falls back to `HTTP <status>` when body has no error field", () => {
    const err = new ApiError(500, { something: "else" });
    assert.strictEqual(err.message, "HTTP 500");
  });

  it("falls back to `HTTP <status>` when body is null", () => {
    const err = new ApiError(404, null);
    assert.strictEqual(err.message, "HTTP 404");
  });

  it("falls back to `HTTP <status>` when body is a string", () => {
    const err = new ApiError(502, "bad gateway");
    assert.strictEqual(err.message, "HTTP 502");
  });

  it("uses `HTTP <status>` when body is not an object", () => {
    const err = new ApiError(503, 42);
    assert.strictEqual(err.message, "HTTP 503");
  });
});

describe("api/client — apiFetch", () => {
  let originalFetch;

  beforeEach(() => {
    originalFetch = global.fetch;
    localStorage.clear();
  });

  afterEach(() => {
    global.fetch = originalFetch;
    localStorage.clear();
  });

  function mockFetch(responder) {
    global.fetch = vi.fn((_path, _opts) =>
      Promise.resolve(responder(_path, _opts)),
    );
  }

  it("issues a GET with Accept header and no body", async () => {
    mockFetch((path, opts) => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve(JSON.stringify({ ok: true })),
      url: path,
      ...opts,
    }));

    const result = await apiFetch("/api/v1/ping");
    assert.deepStrictEqual(result, { ok: true });
    const [calledPath, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(calledPath, "/api/v1/ping");
    assert.strictEqual(calledOpts.method, "GET");
    assert.strictEqual(calledOpts.headers.Accept, "application/json");
    assert.strictEqual(calledOpts.body, undefined);
  });

  it("uses an explicit token argument over the stored one", async () => {
    setStoredToken("stored-token");
    mockFetch(() => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve("{}"),
    }));

    await apiFetch("/api/v1/x", { token: "explicit-token" });
    const [, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(
      calledOpts.headers.Authorization,
      "Bearer explicit-token",
    );
  });

  it("falls back to the stored token when no explicit token is passed", async () => {
    setStoredToken("stored-token");
    mockFetch(() => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve("{}"),
    }));

    await apiFetch("/api/v1/x");
    const [, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(calledOpts.headers.Authorization, "Bearer stored-token");
  });

  it("omits the Authorization header when no token is available", async () => {
    mockFetch(() => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve("{}"),
    }));

    await apiFetch("/api/v1/x");
    const [, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(calledOpts.headers.Authorization, undefined);
  });

  it("serializes object bodies as JSON and sets Content-Type", async () => {
    mockFetch(() => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve("{}"),
    }));

    await apiFetch("/api/v1/x", { method: "POST", body: { a: 1 } });
    const [, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(calledOpts.headers["Content-Type"], "application/json");
    assert.strictEqual(calledOpts.body, JSON.stringify({ a: 1 }));
  });

  it("allows custom headers to override defaults", async () => {
    mockFetch(() => ({
      ok: true,
      status: 200,
      text: () => Promise.resolve("{}"),
    }));

    await apiFetch("/api/v1/x", { headers: { Accept: "text/plain" } });
    const [, calledOpts] = global.fetch.mock.calls[0];
    assert.strictEqual(calledOpts.headers.Accept, "text/plain");
  });

  it("throws ApiError with parsed JSON body on non-2xx responses", async () => {
    mockFetch(() => ({
      ok: false,
      status: 422,
      text: () =>
        Promise.resolve(JSON.stringify({ error: "validation failed" })),
    }));

    await assert.rejects(apiFetch("/api/v1/x"), (err) => {
      assert.ok(err instanceof ApiError);
      assert.strictEqual(err.status, 422);
      assert.strictEqual(err.message, "validation failed");
      return true;
    });
  });

  it("throws ApiError with the raw text when the body is not JSON", async () => {
    mockFetch(() => ({
      ok: false,
      status: 500,
      text: () => Promise.resolve("Internal Server Error"),
    }));

    await assert.rejects(apiFetch("/api/v1/x"), (err) => {
      assert.ok(err instanceof ApiError);
      assert.strictEqual(err.status, 500);
      assert.strictEqual(err.body, "Internal Server Error");
      assert.strictEqual(err.message, "HTTP 500");
      return true;
    });
  });

  it("returns null when the response body is empty", async () => {
    mockFetch(() => ({
      ok: true,
      status: 204,
      text: () => Promise.resolve(""),
    }));

    const result = await apiFetch("/api/v1/x");
    assert.strictEqual(result, null);
  });
});
