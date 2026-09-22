/**
 * Tests for providerConstants helpers.
 *
 * Covers:
 *  - `makeId` produces non-empty, unique client-side ids without
 *    relying on `crypto.randomUUID` (unavailable in non-secure
 *    contexts).
 *  - `emptyProvider` / `emptyModel` return distinct ids and the
 *    expected default shape.
 */

import { describe, it, expect } from "vitest";

import { makeId, emptyProvider, emptyModel } from "./providerConstants";

describe("providerConstants", () => {
  it("makeId returns unique, non-empty ids", () => {
    const ids = new Set(Array.from({ length: 100 }, () => makeId()));

    expect(ids.size).toBe(100);
    for (const id of ids) {
      expect(id).toEqual(expect.any(String));
      expect(id.length).toBeGreaterThan(0);
    }
  });

  it("emptyProvider returns a default provider with a fresh id", () => {
    const a = emptyProvider();
    const b = emptyProvider();

    expect(a).toEqual({
      id: expect.any(String),
      name: "",
      base_url: "",
      api_key: "",
      protocol: "openai",
      auto_models: false,
      tags: [],
      timeout_seconds: null,
      default_context_limit: null,
      default_thinking_effort: null,
      probe_base_url: null,
      auto_probe: true,
      expose_models: false,
      models: [],
    });
    expect(a.id).not.toBe(b.id);
  });

  it("emptyModel returns a default model with a fresh id", () => {
    const a = emptyModel();
    const b = emptyModel();

    expect(a).toEqual({
      id: expect.any(String),
      name: "",
      context_limit: null,
      multi_modal: null,
      thinking_effort: null,
    });
    expect(a.id).not.toBe(b.id);
  });
});
