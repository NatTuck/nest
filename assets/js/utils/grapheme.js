/**
 * Grapheme-aware string utilities using Intl.Segmenter.
 *
 * These utilities count characters as Unicode grapheme clusters (visual characters)
 * rather than UTF-16 code units. This ensures consistency with server-side Elixir
 * which uses String.graphemes/1 for character counting.
 *
 * Example: "💡" has length 2 in UTF-16 but is 1 grapheme cluster.
 */

const segmenter = new Intl.Segmenter({ granularity: "grapheme" });

/**
 * Count the number of grapheme clusters in a string.
 * @param {string} str - The input string
 * @returns {number} The number of grapheme clusters
 */
export function graphemeCount(str) {
  if (!str) return 0;
  return Array.from(segmenter.segment(str)).length;
}

/**
 * Extract a substring by grapheme cluster indices.
 * @param {string} str - The input string
 * @param {number} start - Start index (in graphemes)
 * @param {number} [end] - End index (in graphemes, exclusive)
 * @returns {string} The extracted substring
 */
export function graphemeSlice(str, start, end) {
  if (!str) return "";
  const segments = Array.from(segmenter.segment(str));
  const sliced = segments.slice(start, end);
  return sliced.map((s) => s.segment).join("");
}

/**
 * Get the last n grapheme clusters from a string.
 * @param {string} str - The input string
 * @param {number} n - Number of graphemes to extract from the end
 * @returns {string} The last n graphemes
 */
export function graphemeLast(str, n) {
  if (!str || n <= 0) return "";
  const segments = Array.from(segmenter.segment(str));
  return segments
    .slice(-n)
    .map((s) => s.segment)
    .join("");
}

/**
 * Get the first n grapheme clusters from a string.
 * @param {string} str - The input string
 * @param {number} n - Number of graphemes to extract from the start
 * @returns {string} The first n graphemes
 */
export function graphemeFirst(str, n) {
  if (!str || n <= 0) return "";
  const segments = Array.from(segmenter.segment(str));
  return segments
    .slice(0, n)
    .map((s) => s.segment)
    .join("");
}
