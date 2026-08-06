/**
 * Tests for `js/api/auth.js`.
 *
 * Covers: login, register, and logout calling the right endpoints,
 * storing the returned token on success, and clearing it on logout
 * (best-effort even if the server request fails).
 */

import { describe, it, beforeEach, afterEach, vi } from "vitest";
import assert from "node:assert";
import { login, register, logout } from "./auth";
import { getStoredToken } from "./client";

describe("api/auth", () => {
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

  describe("login", () => {
    it("POSTs username + password to /api/v1/login", async () => {
      mockJson(200, { token: "login-token", user: { id: 1 } });

      await login("alice", "hunter2");

      const [path, opts] = global.fetch.mock.calls[0];
      assert.strictEqual(path, "/api/v1/login");
      assert.strictEqual(opts.method, "POST");
      assert.deepStrictEqual(JSON.parse(opts.body), {
        username: "alice",
        password: "hunter2",
      });
    });

    it("stores the returned token in localStorage", async () => {
      mockJson(200, { token: "stored-login-token", user: { id: 1 } });

      await login("alice", "hunter2");

      assert.strictEqual(getStoredToken(), "stored-login-token");
    });

    it("returns the parsed server response", async () => {
      mockJson(200, { token: "tok", user: { id: 7, username: "alice" } });

      const result = await login("alice", "hunter2");
      assert.strictEqual(result.token, "tok");
      assert.strictEqual(result.user.id, 7);
    });
  });

  describe("register", () => {
    it("POSTs username + password + token to /api/v1/register", async () => {
      mockJson(200, { token: "reg-token", user: { id: 1 } });

      await register({
        username: "bob",
        password: "sekrit",
        token: "first-user",
      });

      const [path, opts] = global.fetch.mock.calls[0];
      assert.strictEqual(path, "/api/v1/register");
      assert.strictEqual(opts.method, "POST");
      assert.deepStrictEqual(JSON.parse(opts.body), {
        username: "bob",
        password: "sekrit",
        token: "first-user",
      });
    });

    it("stores the returned token in localStorage", async () => {
      mockJson(200, { token: "reg-token", user: { id: 1 } });

      await register({
        username: "bob",
        password: "sekrit",
        token: "first-user",
      });

      assert.strictEqual(getStoredToken(), "reg-token");
    });
  });

  describe("logout", () => {
    it("POSTs to /api/v1/logout", async () => {
      mockJson(204, {});

      await logout();

      const [path, opts] = global.fetch.mock.calls[0];
      assert.strictEqual(path, "/api/v1/logout");
      assert.strictEqual(opts.method, "POST");
    });

    it("clears the stored token even when the server call succeeds", async () => {
      mockJson(204, {});
      localStorage.setItem("nest_token", "to-clear");

      await logout();

      assert.strictEqual(getStoredToken(), null);
    });

    it("still clears the stored token when the server call fails", async () => {
      mockJson(500, { error: "boom" });
      localStorage.setItem("nest_token", "to-clear");

      await logout();

      assert.strictEqual(getStoredToken(), null);
    });
  });
});
