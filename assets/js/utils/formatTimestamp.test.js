/**
 * Tests for `js/utils/formatTimestamp.js`.
 *
 * Covers both branches: the early-return for null/empty inputs and
 * the localized-string return for valid timestamps.
 */

import { describe, it } from "vitest";
import assert from "node:assert";
import { formatTimestamp } from "./formatTimestamp";

describe("formatTimestamp", () => {
  it("returns null for null", () => {
    assert.strictEqual(formatTimestamp(null), null);
  });

  it("returns null for undefined", () => {
    assert.strictEqual(formatTimestamp(undefined), null);
  });

  it("returns null for an empty string", () => {
    assert.strictEqual(formatTimestamp(""), null);
  });

  it("returns null for zero", () => {
    assert.strictEqual(formatTimestamp(0), null);
  });

  it("formats a Date instance as a localized string", () => {
    const result = formatTimestamp(new Date("2026-01-15T12:00:00Z"));
    assert.strictEqual(typeof result, "string");
    assert.notStrictEqual(result, null);
    assert.ok(result.length > 0);
  });

  it("formats an ISO string as a localized string", () => {
    const result = formatTimestamp("2026-01-15T12:00:00Z");
    assert.strictEqual(typeof result, "string");
    assert.notStrictEqual(result, null);
  });
});
