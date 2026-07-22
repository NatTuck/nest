/**
 * Format a timestamp as a localized date/time string.
 * Returns null for null/undefined/empty inputs.
 */
export function formatTimestamp(ts) {
  if (!ts) return null;
  return new Date(ts).toLocaleString();
}
