/**
 * TokenUsageChip - displays current context usage for an agent.
 *
 * Renders `lastInput / contextLimit` plus a progress bar and percentage.
 * Hidden entirely when `contextLimit` is null/undefined (model has no
 * configured or discovered limit).
 */

/**
 * Format a token count for display, e.g. 12345 -> "12,345".
 * @param {number} n
 * @returns {string}
 */
function formatTokens(n) {
  if (!Number.isFinite(n)) return "0";
  return Math.round(n).toLocaleString("en-US");
}

/**
 * @param {Object} props
 * @param {number|null|undefined} props.lastInput
 * @param {number|null|undefined} props.contextLimit
 */
export function TokenUsageChip({ lastInput, contextLimit }) {
  if (!contextLimit || contextLimit <= 0) return null;

  const used = Number.isFinite(lastInput) ? Math.max(0, lastInput) : 0;
  const pct = Math.min(100, (used / contextLimit) * 100);

  return (
    <div
      className="flex items-center gap-2 text-xs text-zinc-500"
      data-testid="token-usage-chip"
    >
      <span className="font-mono tabular-nums whitespace-nowrap">
        {formatTokens(used)} / {formatTokens(contextLimit)} tokens
      </span>
      <div
        className="h-1 w-24 rounded bg-zinc-800 overflow-hidden"
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={contextLimit}
        aria-valuenow={used}
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
    </div>
  );
}

export { formatTokens };
