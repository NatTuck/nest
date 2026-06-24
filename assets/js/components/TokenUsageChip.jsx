/**
 * TokenUsageChip - displays current context-window usage for
 * an agent, with a click-to-expand details view.
 *
 * Collapsed (default): a single line showing the context fill
 * (used / limit) and a progress bar.
 *
 * Expanded: three additional lines below — last request's
 * input + cached breakdown, cumulative session token counts,
 * and a USD cost estimate. The whole chip is a single
 * `<button type="button" aria-expanded={...}>` for
 * discoverability; the chevron rotates 180° on expand.
 *
 * The expanded lines are computed entirely from the `usage`
 * object (which the server populates with the canonical
 * per-call and cumulative fields) and a small in-house cost
 * helper. No per-model configuration is needed for the
 * displayed rates — they're hardcoded for now.
 *
 * Hidden entirely when `contextLimit` is null/undefined (the
 * model has no known limit to fill against).
 */

import { useState } from "react";
import { estimateCost, formatCost } from "../utils/cost.js";

/**
 * Format a token count for display, e.g. 12345 -> "12,345".
 * @param {number} n
 * @returns {string}
 */
export function formatTokens(n) {
  if (!Number.isFinite(n)) return "0";
  return Math.round(n).toLocaleString("en-US");
}

/**
 * The total context-window size for the most recent call. This
 * is the numerator the chip should display and the value the
 * progress bar should reflect. `context_input_tokens` is the
 * server-derived sum (input + cache_read + cache_creation).
 * Falls back to `input_tokens` for older wire payloads where
 * the derived field isn't present yet.
 *
 * @param {object} usage
 * @returns {number}
 */
function totalContextTokens(usage) {
  if (!usage) return 0;
  if (Number.isFinite(usage.context_input_tokens)) {
    return usage.context_input_tokens;
  }
  if (Number.isFinite(usage.input_tokens)) {
    // Older wire: server hadn't split cache out. Add the cache
    // fields if they're present (newer server might be talking
    // to an older client).
    const base = usage.input_tokens;
    const cached = Number.isFinite(usage.cache_read_input_tokens)
      ? usage.cache_read_input_tokens
      : 0;
    const created = Number.isFinite(usage.cache_creation_input_tokens)
      ? usage.cache_creation_input_tokens
      : 0;
    return base + cached + created;
  }
  return 0;
}

/**
 * @param {Object} props
 * @param {object|null|undefined} props.usage
 *   The full `cache.usage` map from the agent state. The chip
 *   reads the per-call fields for the current-context view and
 *   the cumulative `total_*` fields for the cost estimate.
 * @param {number|null|undefined} props.contextLimit
 *   The model's context-window size. When null/undefined, the
 *   chip hides entirely.
 */
export function TokenUsageChip({ usage, contextLimit }) {
  const [isExpanded, setIsExpanded] = useState(false);

  if (!contextLimit || contextLimit <= 0) return null;

  const used = totalContextTokens(usage);
  const safeUsed = Math.max(0, used);
  const pct = Math.min(100, (safeUsed / contextLimit) * 100);

  // Per-call breakdown for the "Last" line. When no cache is
  // in play we omit the "+ X cached" suffix entirely so the
  // expanded view stays clean.
  const lastInput = numOr(usage?.input_tokens, 0);
  const lastCached = numOr(usage?.cache_read_input_tokens, 0);
  const showCached = lastCached > 0;

  // Session totals for the "Session" line.
  const sessionInput = numOr(usage?.total_input_tokens, 0);
  const sessionOutput = numOr(usage?.output_tokens, 0);

  const cost = estimateCost(usage);
  const costLabel = `Est. ${formatCost(cost)}`;

  return (
    <div
      data-testid="token-usage-chip"
      className="flex flex-col gap-1 text-xs text-zinc-500"
    >
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        aria-expanded={isExpanded}
        aria-label="Toggle token usage details"
        className="flex items-center gap-2 text-left hover:text-zinc-300 transition-colors"
      >
        <span className="font-mono tabular-nums whitespace-nowrap">
          {formatTokens(safeUsed)} / {formatTokens(contextLimit)} tokens
        </span>
        <div
          className="h-1 w-24 rounded bg-zinc-800 overflow-hidden"
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={contextLimit}
          aria-valuenow={safeUsed}
          aria-label="Context window usage"
        >
          <div
            className="h-full bg-emerald-500 transition-all"
            style={{ width: `${pct}%` }}
          />
        </div>
        <span className="font-mono tabular-nums w-12 text-right">
          {pct.toFixed(1)}%
        </span>
        <svg
          className={`w-3 h-3 text-zinc-500 transition-transform ${
            isExpanded ? "rotate-180" : ""
          }`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M19 9l-7 7-7-7"
          />
        </svg>
      </button>
      {isExpanded && (
        <div
          data-testid="token-usage-details"
          className="flex flex-col gap-0.5 pl-1 text-zinc-500"
        >
          <span className="font-mono tabular-nums whitespace-nowrap">
            Last: {formatTokens(lastInput)} new
            {showCached && <> + {formatTokens(lastCached)} cached</>}
          </span>
          <span className="font-mono tabular-nums whitespace-nowrap">
            Session: {formatTokens(sessionInput)} in /{" "}
            {formatTokens(sessionOutput)} out
          </span>
          <span
            className="font-mono tabular-nums whitespace-nowrap"
            data-testid="token-usage-cost"
          >
            {costLabel}
          </span>
        </div>
      )}
    </div>
  );
}

function numOr(v, fallback) {
  return Number.isFinite(v) ? v : fallback;
}
