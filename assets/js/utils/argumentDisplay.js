/**
 * Sorts a tool's argument object for display purposes.
 *
 * The LLM can emit arguments in any order based on its tool schema and
 * reasoning. For tools like `write_file`, this can mean a long `content`
 * field appears before the short `path` field, pushing the path off the
 * 3-line preview in the chat UI.
 *
 * Sorting by combined key + value length (ascending) puts short
 * identifiers (path, name, id) first and long content (file body,
 * command output) last, so the user sees the identifying info up front
 * and the content is truncated predictably.
 *
 * JavaScript's `Array.prototype.sort` is stable, so entries with equal
 * lengths preserve their original insertion order. Non-objects
 * (null, undefined, primitives) are returned as-is.
 *
 * @param {object | null | undefined} args
 *   The arguments object to sort for display.
 * @returns {object | null | undefined}
 *   A new object with the same entries in display order. Returns the
 *   input unchanged for non-objects.
 */
export function sortArgumentsForDisplay(args) {
  if (args === null || typeof args !== "object" || Array.isArray(args)) {
    return args;
  }

  const entries = Object.entries(args).map(([key, value]) => {
    const valueStr = typeof value === "string" ? value : JSON.stringify(value);
    return { key, value, length: key.length + valueStr.length };
  });

  entries.sort((a, b) => a.length - b.length);

  const sorted = {};
  for (const { key, value } of entries) {
    sorted[key] = value;
  }
  return sorted;
}
