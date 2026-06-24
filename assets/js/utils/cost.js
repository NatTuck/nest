/**
 * Cost estimation for an LLM session, in USD.
 *
 * Mirror of `Nest.Tokens.Cost.estimate/1` in the Elixir
 * codebase. The server does NOT ship the cost number over the
 * wire — the UI computes it from the raw token counts so the
 * rates can be tweaked here without a server change. If you
 * change the rates in one place, change them in both.
 *
 * Formula (per 1,000,000 tokens):
 *   * Input           @ $1.00
 *   * Cached input    @ $0.25
 *   * Output          @ $4.00
 *
 * `output_tokens` already includes `reasoning_tokens` per both
 * providers' wire formats, so reasoning output is billed
 * naturally — there's no separate term for it.
 *
 * `cache_creation_input_tokens` is captured for the API logs
 * but not added separately; it's a subset of `input_tokens`
 * (per Anthropic's wire format) and the input rate already
 * covers it.
 */

/**
 * Per-million-token rates, in USD. Kept as a named constant so
 * the values are easy to find and tweak.
 */
export const COST_RATES = {
  inputPerMillion: 1.0,
  cachedInputPerMillion: 0.25,
  outputPerMillion: 4.0,
};

/**
 * Estimate the cumulative session cost in USD.
 *
 * Accepts the `usage_totals` map from the server. Missing
 * fields default to 0 so the function is safe against older
 * wire payloads (server in the middle of a rollout) and
 * against tests that don't populate every key.
 *
 * @param {{
 *   total_input_tokens?: number,
 *   total_cache_read_input_tokens?: number,
 *   output_tokens?: number,
 * }} usageTotals
 * @returns {number} The estimated cost in USD, as a plain JS
 *   number. Precision is good to ~1e-6; the UI formats to
 *   4 decimal places, well above the float floor.
 */
export function estimateCost(usageTotals) {
  if (!usageTotals || typeof usageTotals !== "object") return 0;
  const input = num(usageTotals.total_input_tokens);
  const cached = num(usageTotals.total_cache_read_input_tokens);
  const output = num(usageTotals.output_tokens);
  return (
    (input * COST_RATES.inputPerMillion +
      cached * COST_RATES.cachedInputPerMillion +
      output * COST_RATES.outputPerMillion) /
    1_000_000
  );
}

/**
 * Format a cost number as a USD string, picking a precision
 * that matches the magnitude so sub-cent numbers don't all
 * read as `$0.00`.
 *
 *  - $0.0000 (4 decimals) for amounts < $0.01
 *  - $0.000 (3 decimals) for amounts < $1
 *  - $0.00 (2 decimals) for amounts < $100
 *  - $X,XXX.XX (2 decimals, thousands separator) for ≥ $100
 *
 * @param {number} n
 * @returns {string} The cost formatted as a USD string.
 */
export function formatCost(n) {
  if (!Number.isFinite(n) || n < 0) return "$0.00";
  if (n < 0.01) return `$${n.toFixed(4)}`;
  if (n < 1) return `$${n.toFixed(3)}`;
  if (n < 100) return `$${n.toFixed(2)}`;
  return `$${n.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

function num(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}
