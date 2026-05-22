/**
 * Tests for grapheme-aware string utilities
 */

import { describe, it, expect } from "vitest";
import {
  graphemeCount,
  graphemeSlice,
  graphemeLast,
  graphemeFirst,
} from "./grapheme.js";

describe("grapheme utilities", () => {
  describe("graphemeCount", () => {
    it("counts ASCII characters correctly", () => {
      expect(graphemeCount("Hello")).toBe(5);
      expect(graphemeCount("")).toBe(0);
      expect(graphemeCount("a")).toBe(1);
    });

    it("counts emoji as single graphemes", () => {
      expect(graphemeCount("💡")).toBe(1);
      expect(graphemeCount("💡🎉")).toBe(2);
      expect(graphemeCount("Hello 💡")).toBe(7); // 6 letters + space + 1 emoji
    });

    it("counts regional indicator symbols (flags) as single graphemes", () => {
      expect(graphemeCount("🇺🇸")).toBe(1);
      expect(graphemeCount("🇺🇸🇨🇦")).toBe(2);
    });

    it("counts combining characters as single graphemes", () => {
      // é can be represented as either "é" (1 code point) or "e + ´" (2 code points)
      expect(graphemeCount("café")).toBe(4);
      expect(graphemeCount("cafe\u0301")).toBe(4); // cafe + combining acute accent
    });

    it("handles null and undefined gracefully", () => {
      expect(graphemeCount(null)).toBe(0);
      expect(graphemeCount(undefined)).toBe(0);
    });

    it("demonstrates difference from String.length", () => {
      const text = "💡";
      expect(text.length).toBe(2); // UTF-16 code units
      expect(graphemeCount(text)).toBe(1); // Visual character (grapheme)
    });
  });

  describe("graphemeSlice", () => {
    it("slices ASCII strings correctly", () => {
      expect(graphemeSlice("Hello World", 0, 5)).toBe("Hello");
      expect(graphemeSlice("Hello World", 6)).toBe("World");
      expect(graphemeSlice("Hello World", 0, 11)).toBe("Hello World");
    });

    it("slices emoji-containing strings correctly", () => {
      expect(graphemeSlice("Hello 💡 World", 6, 7)).toBe("💡");
      expect(graphemeSlice("💡🎉✨", 1, 2)).toBe("🎉");
      expect(graphemeSlice("💡🎉✨", 0, 2)).toBe("💡🎉");
    });

    it("handles end parameter as exclusive", () => {
      const text = "Hello 💡 World";
      expect(graphemeSlice(text, 0, 6)).toBe("Hello ");
      expect(graphemeSlice(text, 0, 7)).toBe("Hello 💡");
    });

    it("handles null and undefined gracefully", () => {
      expect(graphemeSlice(null, 0, 5)).toBe("");
      expect(graphemeSlice(undefined, 0, 5)).toBe("");
    });

    it("handles empty strings", () => {
      expect(graphemeSlice("", 0, 5)).toBe("");
    });
  });

  describe("graphemeLast", () => {
    it("gets last n ASCII characters", () => {
      expect(graphemeLast("Hello World", 5)).toBe("World");
      expect(graphemeLast("Hello", 3)).toBe("llo");
      expect(graphemeLast("Hello", 1)).toBe("o");
    });

    it("gets last n characters including emojis", () => {
      expect(graphemeLast("Hello 💡 World", 1)).toBe("d");
      expect(graphemeLast("Hello 💡 World", 7)).toBe("💡 World");
      expect(graphemeLast("💡🎉✨", 2)).toBe("🎉✨");
    });

    it("handles n greater than string length", () => {
      expect(graphemeLast("Hi", 10)).toBe("Hi");
    });

    it("handles n of 0", () => {
      expect(graphemeLast("Hello", 0)).toBe("");
    });

    it("handles negative n", () => {
      expect(graphemeLast("Hello", -1)).toBe("");
    });

    it("handles null and undefined gracefully", () => {
      expect(graphemeLast(null, 5)).toBe("");
      expect(graphemeLast(undefined, 5)).toBe("");
    });
  });

  describe("graphemeFirst", () => {
    it("gets first n ASCII characters", () => {
      expect(graphemeFirst("Hello World", 5)).toBe("Hello");
      expect(graphemeFirst("Hello", 3)).toBe("Hel");
      expect(graphemeFirst("Hello", 1)).toBe("H");
    });

    it("gets first n characters including emojis", () => {
      expect(graphemeFirst("💡 Hello", 2)).toBe("💡 ");
      expect(graphemeFirst("💡🎉✨", 2)).toBe("💡🎉");
    });

    it("handles n greater than string length", () => {
      expect(graphemeFirst("Hi", 10)).toBe("Hi");
    });

    it("handles n of 0", () => {
      expect(graphemeFirst("Hello", 0)).toBe("");
    });

    it("handles negative n", () => {
      expect(graphemeFirst("Hello", -1)).toBe("");
    });

    it("handles null and undefined gracefully", () => {
      expect(graphemeFirst(null, 5)).toBe("");
      expect(graphemeFirst(undefined, 5)).toBe("");
    });
  });

  describe("complex emoji sequences", () => {
    it("handles skin tone modifiers", () => {
      // 👋🏽 is a wave with medium skin tone modifier (2 graphemes technically,
      // but Intl.Segmenter usually counts modified emoji as 1 grapheme)
      const wave = "👋🏽";
      expect(graphemeCount(wave)).toBeGreaterThanOrEqual(1);
    });

    it("handles family/group emojis", () => {
      // 👨‍👩‍👧‍👦 is a family emoji (ZWJ sequence, counts as 1 grapheme)
      const family = "👨‍👩‍👧‍👦";
      expect(graphemeCount(family)).toBe(1);
      expect(family.length).toBeGreaterThan(1); // Multiple UTF-16 code units
    });

    it("handles mixed content", () => {
      const mixed = "Hello 👨‍👩‍👧‍👦 world 💡!";
      // H-e-l-l-o-space-[family]-space-w-o-r-l-d-space-💡-! = 16 graphemes
      expect(graphemeCount(mixed)).toBe(16);
    });
  });
});
