/**
 * Tests for sortArgumentsForDisplay.
 *
 * Covers:
 * - Non-object inputs returned as-is
 * - Empty object returns empty
 * - Single-key object returned unchanged
 * - Multiple keys sorted by combined length (ascending)
 * - Stable sort for ties (preserves insertion order)
 * - Non-string values (numbers, booleans, nested objects, arrays)
 * - Realistic tool call args (read_file, write_file)
 */

import { describe, it, expect } from "vitest";
import { sortArgumentsForDisplay } from "./argumentDisplay";

describe("sortArgumentsForDisplay", () => {
  describe("non-object inputs", () => {
    it("returns null unchanged", () => {
      expect(sortArgumentsForDisplay(null)).toBe(null);
    });

    it("returns undefined unchanged", () => {
      expect(sortArgumentsForDisplay(undefined)).toBe(undefined);
    });

    it("returns a string unchanged", () => {
      expect(sortArgumentsForDisplay("hello")).toBe("hello");
    });

    it("returns a number unchanged", () => {
      expect(sortArgumentsForDisplay(42)).toBe(42);
    });

    it("returns an array unchanged (arrays are objects but not the target shape)", () => {
      const arr = ["a", "b"];
      expect(sortArgumentsForDisplay(arr)).toBe(arr);
    });
  });

  describe("empty and trivial objects", () => {
    it("returns an empty object as an empty object", () => {
      const result = sortArgumentsForDisplay({});
      expect(result).toEqual({});
    });

    it("returns a single-key object unchanged", () => {
      const input = { path: "/foo" };
      const result = sortArgumentsForDisplay(input);
      expect(result).toEqual({ path: "/foo" });
      expect(Object.keys(result)).toEqual(["path"]);
    });
  });

  describe("sorting by combined length", () => {
    it("sorts multiple keys by (key length + value length) ascending", () => {
      const input = {
        command: "long shell command with many flags and arguments",
        path: "/short/path",
        v: true,
      };
      const result = sortArgumentsForDisplay(input);
      expect(Object.keys(result)).toEqual(["v", "path", "command"]);
    });

    it("puts a short path before a long content (realistic write_file case)", () => {
      const input = {
        path: "/home/user/file.txt",
        content:
          "This is a very long piece of content that exceeds the preview line limit and would otherwise push the path off the truncated preview if it appeared second.",
      };
      const result = sortArgumentsForDisplay(input);
      expect(Object.keys(result)).toEqual(["path", "content"]);
    });

    it("does not mutate the input object", () => {
      const input = { b: "22", a: "1" };
      sortArgumentsForDisplay(input);
      expect(Object.keys(input)).toEqual(["b", "a"]);
    });
  });

  describe("stable sort for ties", () => {
    it("preserves original order when entries have equal combined length", () => {
      // All entries have combined length 2 ("a" + "x", "b" + "y", "c" + "z")
      const input = { a: "x", b: "y", c: "z" };
      const result = sortArgumentsForDisplay(input);
      expect(Object.keys(result)).toEqual(["a", "b", "c"]);
    });

    it("preserves original order for ties in a longer object", () => {
      // "k1" + "ab" = 4, "k2" + "ab" = 4, "short" + "x" = 6, "k3" + "abc" = 5
      const input = { k1: "ab", k2: "ab", k3: "abc", short: "x" };
      const result = sortArgumentsForDisplay(input);
      // Shortest first ("k1", "k2" tied at 4, then "k3" at 5, then "short" at 6).
      // Within the tie, original order is preserved.
      expect(Object.keys(result)).toEqual(["k1", "k2", "k3", "short"]);
    });
  });

  describe("non-string values", () => {
    it("handles numeric values", () => {
      const input = { count: 12345, name: "x" };
      const result = sortArgumentsForDisplay(input);
      // "name" (4 + 1 = 5) before "count" (5 + 5 = 10)
      expect(Object.keys(result)).toEqual(["name", "count"]);
    });

    it("handles boolean values", () => {
      const input = { verbose: true, label: "abcde" };
      const result = sortArgumentsForDisplay(input);
      // "verbose" (7 + 4 = 11) before "label" (5 + 5 = 10)... actually label is shorter
      // "label" (5 + 5 = 10) before "verbose" (7 + 4 = 11)
      expect(Object.keys(result)).toEqual(["label", "verbose"]);
    });

    it("handles nested object values", () => {
      const input = {
        path: "/x",
        options: { recursive: true, depth: 3, filter: "*.md" },
      };
      const result = sortArgumentsForDisplay(input);
      // path is shorter
      expect(Object.keys(result)).toEqual(["path", "options"]);
    });

    it("handles null values", () => {
      const input = { a: null, b: "x" };
      const result = sortArgumentsForDisplay(input);
      // "b" (1 + 1 = 2) before "a" (1 + 4 = 5) -- "null" is 4 chars when JSON.stringified
      expect(Object.keys(result)).toEqual(["b", "a"]);
    });
  });

  describe("realistic tool call shapes", () => {
    it("read_file: single key returned as-is", () => {
      const input = { path: "/home/user/some-file.md" };
      const result = sortArgumentsForDisplay(input);
      expect(Object.keys(result)).toEqual(["path"]);
    });

    it("shell_cmd: short command first, long arg last", () => {
      const input = {
        command: "find /very/long/path -name '*.md' -type f -exec wc -l {} +",
        verbose: true,
      };
      const result = sortArgumentsForDisplay(input);
      expect(Object.keys(result)).toEqual(["verbose", "command"]);
    });
  });
});
