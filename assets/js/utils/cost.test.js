/**
 * Tests for the JS cost helpers. Mirror of
 * `test/nest/tokens/cost_test.exs` — the two test files
 * should be updated together whenever the rates change.
 */
import { describe, it, expect } from "vitest";
import { estimateCost, formatCost, COST_RATES } from "./cost.js";

describe("estimateCost", () => {
  it("returns 0 for missing or non-object input", () => {
    expect(estimateCost(null)).toBe(0);
    expect(estimateCost(undefined)).toBe(0);
    expect(estimateCost("not a map")).toBe(0);
    expect(estimateCost({})).toBe(0);
  });

  it("1M input at $1/M = $1", () => {
    expect(estimateCost({ total_input_tokens: 1_000_000 })).toBeCloseTo(1, 6);
  });

  it("1M output at $4/M = $4", () => {
    expect(estimateCost({ output_tokens: 1_000_000 })).toBeCloseTo(4, 6);
  });

  it("1M cached input at $0.25/M = $0.25", () => {
    expect(
      estimateCost({ total_cache_read_input_tokens: 1_000_000 }),
    ).toBeCloseTo(0.25, 6);
  });

  it("sums all three components for a mixed session", () => {
    expect(
      estimateCost({
        total_input_tokens: 1_000_000,
        total_cache_read_input_tokens: 1_000_000,
        output_tokens: 1_000_000,
      }),
    ).toBeCloseTo(5.25, 6);
  });

  it("treats missing fields as 0", () => {
    expect(estimateCost({ total_input_tokens: 500_000 })).toBeCloseTo(0.5, 6);
  });

  it("treats non-numeric field values as 0", () => {
    expect(
      estimateCost({
        total_input_tokens: null,
        output_tokens: undefined,
        total_cache_read_input_tokens: "nope",
      }),
    ).toBe(0);
  });

  it("reasoning tokens are included via output_tokens (no separate term)", () => {
    const withReasoning = estimateCost({
      output_tokens: 1_000_000,
      reasoning_tokens: 800_000,
    });
    const withoutReasoning = estimateCost({
      output_tokens: 1_000_000,
      reasoning_tokens: 0,
    });
    expect(withReasoning).toBe(withoutReasoning);
    expect(withReasoning).toBeCloseTo(4, 6);
  });

  it("ignores per-call fields (input_tokens, cache_read_input_tokens)", () => {
    // The cost module uses the cumulative session fields, not
    // the per-call overwrite fields.
    expect(
      estimateCost({
        input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000,
        cache_creation_input_tokens: 1_000_000,
      }),
    ).toBe(0);
  });
});

describe("formatCost", () => {
  it("formats sub-cent amounts with 4 decimals", () => {
    expect(formatCost(0.0001)).toBe("$0.0001");
    expect(formatCost(0.005)).toBe("$0.0050");
  });

  it("formats sub-dollar amounts with 3 decimals", () => {
    expect(formatCost(0.057)).toBe("$0.057");
    expect(formatCost(0.5)).toBe("$0.500");
  });

  it("formats sub-$100 amounts with 2 decimals", () => {
    expect(formatCost(1.23)).toBe("$1.23");
    expect(formatCost(99.99)).toBe("$99.99");
  });

  it("formats ≥$100 amounts with thousands separator", () => {
    expect(formatCost(100)).toBe("$100.00");
    expect(formatCost(1234.56)).toBe("$1,234.56");
  });

  it("returns $0.00 for invalid or negative input", () => {
    expect(formatCost(Number.NaN)).toBe("$0.00");
    expect(formatCost(-1)).toBe("$0.00");
  });
});

describe("COST_RATES", () => {
  it("matches the user-specified hardcoded values", () => {
    // If you change these rates, change them in
    // `lib/nest/tokens/cost.ex` too — and update both test
    // files.
    expect(COST_RATES.inputPerMillion).toBe(1.0);
    expect(COST_RATES.cachedInputPerMillion).toBe(0.25);
    expect(COST_RATES.outputPerMillion).toBe(4.0);
  });
});
