/**
 * Tests for store/index.js
 * Tests all branches with meaningful, externally visible behavior
 */

import { describe, it, beforeEach, vi, expect } from "vitest";
import { useStore } from "./index";

describe("store", () => {
  beforeEach(() => {
    useStore.getState()._reset();
    vi.restoreAllMocks();
  });

  describe("operations on non-existent agents", () => {
    it("gracefully handles all operations when agent cache does not exist", () => {
      const initialCache = useStore.getState().agentsCache;

      // All these should return early without throwing
      useStore.getState().setAgentDisconnected("non-existent");
      expect(useStore.getState().agentsCache).toBe(initialCache);

      const deltaResult = useStore.getState().addChatDelta("non-existent", {
        index: 0,
        content: "test",
        charsStart: 0,
        charsEnd: 4,
      });
      expect(deltaResult).toEqual({ applied: false, needsSync: false });

      useStore.getState().addChatMessage("non-existent", {
        index: 0,
        role: "user",
        content: "test",
      });
      expect(useStore.getState().agentsCache).toBe(initialCache);

      useStore.getState().addUserMessage("non-existent", "test");
      expect(useStore.getState().agentsCache).toBe(initialCache);

      useStore.getState().clearPartial("non-existent");
      expect(useStore.getState().agentsCache).toBe(initialCache);

      useStore.getState().setWaitingForResponse("non-existent", true);
      expect(useStore.getState().agentsCache).toBe(initialCache);

      useStore.getState().syncAgentMessages("non-existent", {
        messages: [],
        messageCount: 0,
      });
      expect(useStore.getState().agentsCache).toBe(initialCache);
    });
  });

  describe("setAgentConnected", () => {
    it("preserves existing messages when they exceed server messages", () => {
      // Setup: Create agent with 3 messages
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().agentsCache["agent-1"].messages = [
        { index: 0, role: "user", content: "A" },
        { index: 1, role: "assistant", content: "B" },
        { index: 2, role: "user", content: "C" },
      ];

      // Server sends only 2 messages
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
        ],
        messageCount: 1,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(3);
      expect(cache.messages[2].content).toBe("C");
    });

    it("calculates lastIndex from messages when present", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messages: [
          { index: 5, role: "user", content: "A" },
          { index: 10, role: "assistant", content: "B" },
        ],
      });

      expect(useStore.getState().agentsCache["agent-1"].lastIndex).toBe(10);
    });

    it("defaults to -1 when no messages", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messages: [],
        messageCount: 7,
      });

      expect(useStore.getState().agentsCache["agent-1"].lastIndex).toBe(-1);
    });

    it("defaults to -1 when neither messages nor messageCount present", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
      });

      expect(useStore.getState().agentsCache["agent-1"].lastIndex).toBe(-1);
    });

    it("uses payload model when provided", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      expect(useStore.getState().agentsCache["agent-1"].model?.name).toBe(
        "gpt-4",
      );
    });

    it("preserves existing model when payload has no model", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().agentsCache["agent-1"].model = { name: "claude-3" };

      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
      });

      expect(useStore.getState().agentsCache["agent-1"].model?.name).toBe(
        "claude-3",
      );
    });

    it("defaults to null when no model in payload or existing cache", () => {
      useStore.getState().setAgentConnecting("agent-1");

      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
      });

      expect(useStore.getState().agentsCache["agent-1"].model).toBeNull();
    });
  });

  describe("setAgentConnecting", () => {
    it("creates new cache when agent does not exist", () => {
      useStore.getState().setAgentConnecting("new-agent");

      const cache = useStore.getState().agentsCache["new-agent"];
      expect(cache).toBeDefined();
      expect(cache.messages).toEqual([]);
      expect(cache.partial).toBeNull();
      expect(cache.lastIndex).toBe(-1);
      expect(cache.status).toBe("connecting");
      expect(cache.error).toBeNull();
      expect(cache.model).toBeNull();
    });

    it("updates existing cache status when agent exists", () => {
      // Setup existing cache
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().agentsCache["agent-1"].messages = [
        { index: 0, content: "test" },
      ];
      useStore.getState().agentsCache["agent-1"].status = "error";
      useStore.getState().agentsCache["agent-1"].error = "Old error";

      useStore.getState().setAgentConnecting("agent-1");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(1);
      expect(cache.status).toBe("connecting");
      expect(cache.error).toBeNull();
    });
  });

  describe("setAgentError", () => {
    it("creates new cache when agent does not exist", () => {
      useStore.getState().setAgentError("new-agent", "Connection failed");

      const cache = useStore.getState().agentsCache["new-agent"];
      expect(cache).toBeDefined();
      expect(cache.status).toBe("error");
      expect(cache.error).toBe("Connection failed");
      expect(cache.messages).toEqual([]);
    });

    it("updates existing cache when agent exists", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().agentsCache["agent-1"].messages = [
        { index: 0, content: "test" },
      ];

      useStore.getState().setAgentError("agent-1", "Model error");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.status).toBe("error");
      expect(cache.error).toBe("Model error");
      expect(cache.messages).toHaveLength(1);
    });
  });

  describe("addChatDelta with emoji content", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("handles overlap correctly with emoji characters", () => {
      // 💡 is 2 UTF-16 code units but 1 grapheme
      // Server sends positions in graphemes, not code units
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello 💡",
        charsReceived: 7, // 7 graphemes: H-e-l-l-o-space-💡
      };

      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "💡 world", // Starts at grapheme position 6 (the emoji)
        charsStart: 6,
        charsEnd: 13, // 7 graphemes total
      });

      expect(result.applied).toBe(true);
      expect(result.overlapMismatch).toBeFalsy();
      expect(useStore.getState().agentsCache["agent-1"].partial.content).toBe(
        "Hello 💡 world",
      );
    });

    it("shows OK integrity check with emoji content", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Content with emoji: "Hi 💡" = 4 graphemes (H-i-space-💡)
      // But payload.content.length in UTF-16 would be 5 (💡 = 2 code units)
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hi 💡",
        charsReceived: 4, // grapheme count matches server
      };

      // Send overlapping delta
      useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "💡 there",
        charsStart: 3, // Start at 3rd grapheme (space before 💡)
        charsEnd: 9, // End at position 9
      });

      // Should not warn about mismatch since overlap matches
      const mismatchWarnings = warnSpy.mock.calls.filter(
        (call) =>
          typeof call[0] === "string" &&
          call[0].includes("Delta overlap mismatch"),
      );
      expect(mismatchWarnings).toHaveLength(0);

      warnSpy.mockRestore();
    });

    it("correctly counts graphemes vs UTF-16 code units", () => {
      // This test verifies the grapheme utilities are working
      // "Hello 💡🎉" = 8 graphemes, 10 UTF-16 code units
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello 💡🎉",
        charsReceived: 8, // server counts graphemes
      };

      // Delta that overlaps by 3 graphemes: " 💡🎉" (space + 2 emojis)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: " 💡🎉! more", // Starts with the expected overlap
        charsStart: 5, // Start at position 5 (after "Hello")
        charsEnd: 13, // " 💡🎉! more" = 8 graphemes, so end = 5 + 8 = 13
      });

      expect(result.applied).toBe(true);
      // Content should be: "Hello 💡🎉! more" (overlap matches, no mismatch warning)
      expect(useStore.getState().agentsCache["agent-1"].partial.content).toBe(
        "Hello 💡🎉! more",
      );
      expect(
        useStore.getState().agentsCache["agent-1"].partial.charsReceived,
      ).toBe(13);
    });

    it("handles multi-byte emojis in overlap detection", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // 🇺🇸 is a regional indicator symbol (2 code points = 1 grapheme)
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Flag: 🇺🇸",
        charsReceived: 10, // Intentionally wrong to trigger MISMATCH (actual is 7)
      };

      // Send delta with mismatch (different flag)
      useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "🇨🇦 end", // Canada flag instead of US
        charsStart: 6, // Start after "Flag: "
        charsEnd: 9,
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      // Verify integrity check shows grapheme count mismatch
      expect(warningArg.integrityCheck.contentVsCharsReceived).toContain(
        "graphemeCount=7",
      );
      expect(warningArg.integrityCheck.contentVsCharsReceived).toContain(
        "MISMATCH",
      );

      warnSpy.mockRestore();
    });
  });

  describe("addChatMessage with emoji content", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("warns with grapheme counts for emoji content mismatch", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Partial has emoji, final message has different content
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Hello 💡 world",
        charsReceived: 13, // H-e-l-l-o-space-💡-space-w-o-r-l-d (13 graphemes)
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Hello 🎉 world", // Different emoji
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];

      // Should show grapheme counts, not UTF-16 lengths
      expect(warningArg.partial.graphemeCount).toBe(13);
      expect(warningArg.message.graphemeCount).toBe(13); // Same grapheme count

      warnSpy.mockRestore();
    });

    it("correctly identifies extra content with emojis", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Partial has extra emoji
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Test 💡 extra",
        charsReceived: 11, // T-e-s-t-space-💡-space-e-x-t-r-a (11 graphemes)
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Test 💡", // Without " extra"
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];

      // Should correctly identify " extra" as the extra content
      expect(warningArg.diff.extraInPartial).toBe(" extra");
      expect(warningArg.diff.extraInMessage).toBeNull();
      // Length diff should be 6 graphemes (space + e-x-t-r-a)
      expect(warningArg.diff.lengthDiff).toBe(6);

      warnSpy.mockRestore();
    });
  });

  describe("addChatDelta", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("reuses existing partial when index matches", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 5,
        content: "Hello",
        charsReceived: 5,
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        content: " world",
        charsStart: 5,
        charsEnd: 11,
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.content).toBe("Hello world");
      expect(partial.index).toBe(5);
    });

    it("creates new partial when index differs", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 3,
        content: "Old content",
        charsReceived: 11,
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        content: "New content",
        charsStart: 0,
        charsEnd: 11,
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.content).toBe("New content");
      expect(partial.index).toBe(5);
    });

    it("detects gap and requests sync when delta starts beyond current position", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello",
        charsReceived: 5,
      };

      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "gap",
        charsStart: 10,
        charsEnd: 13,
      });

      expect(result).toEqual({ applied: false, needsSync: true });
      expect(useStore.getState().agentsCache["agent-1"].partial.content).toBe(
        "Hello",
      );
    });

    it("handles overlap without mismatch by slicing and appending", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello",
        charsReceived: 5,
      };

      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "lo world",
        charsStart: 3,
        charsEnd: 11,
      });

      expect(result.applied).toBe(true);
      expect(result.overlapMismatch).toBeFalsy();
      expect(useStore.getState().agentsCache["agent-1"].partial.content).toBe(
        "Hello world",
      );
    });

    it("detects overlap mismatch with content length truncation", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Create partial with > 100 chars to trigger truncation
      const longContent = "a".repeat(150);
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: longContent,
        charsReceived: 150,
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "xyz",
        charsStart: 148,
        charsEnd: 151,
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      // Should show truncated content with ... prefix
      expect(warningArg.partial.content).toMatch(/^\.\.\./);

      warnSpy.mockRestore();
    });

    it("shows OK in integrity check when content length matches charsReceived", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello",
        charsReceived: 5,
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "xyz",
        charsStart: 3,
        charsEnd: 6,
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      expect(warningArg.integrityCheck.contentVsCharsReceived).toBe("OK");

      warnSpy.mockRestore();
    });

    it("shows MISMATCH in integrity check when content length differs from charsReceived", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Manually set inconsistent state
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello", // length is 5
        charsReceived: 10, // but claims 10
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "xyz",
        charsStart: 8, // within charsReceived but content is shorter
        charsEnd: 11,
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      expect(warningArg.integrityCheck.contentVsCharsReceived).toContain(
        "MISMATCH",
      );

      warnSpy.mockRestore();
    });

    it("skips applying when overlap consumes entire delta", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello world",
        charsReceived: 11,
      };

      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "world",
        charsStart: 6,
        charsEnd: 11,
      });

      expect(result.applied).toBe(false);
      expect(result.overlapMismatch).toBeFalsy();
      expect(useStore.getState().agentsCache["agent-1"].partial.content).toBe(
        "Hello world",
      );
    });

    it("includes overlapMismatch: false when fully overlapped with no mismatch", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Hello world",
        charsReceived: 11,
      };

      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "world",
        charsStart: 6,
        charsEnd: 11,
      });

      expect(result.overlapMismatch).toBe(false);
    });
  });

  describe("addChatMessage", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("warns when final message differs from partial content", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Streaming incomplet",
        charsReceived: 19,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Streaming incomplete",
      });

      expect(warnSpy).toHaveBeenCalled();
      expect(warnSpy.mock.calls[0][0]).toContain(
        "[agent:agent-1] Final message differs from partial:",
      );

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.partial).toBeNull();
      expect(cache.messages[0].content).toBe("Streaming incomplete");

      warnSpy.mockRestore();
    });

    it("does not warn when final message matches partial content", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Exact match",
        charsReceived: 11,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Exact match",
      });

      expect(warnSpy).not.toHaveBeenCalled();

      warnSpy.mockRestore();
    });

    it("handles content truncation in mismatch warning for long partial", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Create partial with > 200 chars
      const longContent = "x".repeat(250);
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: longContent,
        charsReceived: 250,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Different",
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      // Should show truncated content
      expect(warningArg.partial.content).toContain("...");

      warnSpy.mockRestore();
    });

    it("handles content truncation in mismatch warning for long message", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Short",
        charsReceived: 5,
      };

      // Create message with > 200 chars
      const longContent = "y".repeat(250);
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: longContent,
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      // Should show truncated content
      expect(warningArg.message.content).toContain("...");

      warnSpy.mockRestore();
    });

    it("includes extraInPartial when partial is longer than message", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Hello world extra",
        charsReceived: 17,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Hello world",
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      expect(warningArg.diff.extraInPartial).toBe(" extra");
      expect(warningArg.diff.extraInMessage).toBeNull();
      expect(warningArg.diff.lengthDiff).toBe(6);

      warnSpy.mockRestore();
    });

    it("includes extraInMessage when message is longer than partial", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Hello world",
        charsReceived: 11,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Hello world extra",
      });

      expect(warnSpy).toHaveBeenCalled();
      const warningArg = warnSpy.mock.calls[0][1];
      expect(warningArg.diff.extraInPartial).toBeNull();
      expect(warningArg.diff.extraInMessage).toBe(" extra");
      expect(warningArg.diff.lengthDiff).toBe(-6);

      warnSpy.mockRestore();
    });

    it("handles null partial content in mismatch check", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: null,
        charsReceived: 0,
      };

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Has content",
      });

      expect(warnSpy).toHaveBeenCalled();
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages[0].content).toBe("Has content");

      warnSpy.mockRestore();
    });

    it("replaces message with same index instead of duplicating", () => {
      // Add initial message
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "Original",
      });

      expect(useStore.getState().agentsCache["agent-1"].messages).toHaveLength(
        1,
      );

      // Add message with same index
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "Updated",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(1);
      expect(messages[0].content).toBe("Updated");
    });

    it("appends message with new index", () => {
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "First",
      });

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Second",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(2);
      expect(messages[1].content).toBe("Second");
    });

    it("handles falsy message content by defaulting to empty string", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Partial content",
        charsReceived: 15,
      };

      // Add message with null content to trigger content || "" branch
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: null,
      });

      // Should complete without errors
      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].content).toBeNull();

      warnSpy.mockRestore();
    });

    it("preserves other messages when replacing at existing index", () => {
      // Add two messages
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "First",
      });
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Second",
      });

      // Replace the first message - this triggers the map branch
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "Updated First",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(2);
      expect(messages[0].content).toBe("Updated First");
      expect(messages[1].content).toBe("Second");
    });
  });

  describe("removeAgent", () => {
    it("removes agent from agents list and deletes cache", () => {
      // Setup
      useStore.getState().addAgent({ id: "agent-1", model: "gpt-4" });
      useStore.getState().setAgentConnecting("agent-1");

      expect(useStore.getState().agents).toHaveLength(1);
      expect(useStore.getState().agentsCache["agent-1"]).toBeDefined();

      useStore.getState().removeAgent("agent-1");

      expect(useStore.getState().agents).toHaveLength(0);
      expect(useStore.getState().agentsCache["agent-1"]).toBeUndefined();
    });
  });

  describe("clearAgentCache", () => {
    it("deletes only the agent cache while keeping agents list", () => {
      // Setup
      useStore.getState().addAgent({ id: "agent-1", model: "gpt-4" });
      useStore.getState().setAgentConnecting("agent-1");

      expect(useStore.getState().agents).toHaveLength(1);
      expect(useStore.getState().agentsCache["agent-1"]).toBeDefined();

      useStore.getState().clearAgentCache("agent-1");

      expect(useStore.getState().agents).toHaveLength(1);
      expect(useStore.getState().agentsCache["agent-1"]).toBeUndefined();
    });
  });

  describe("normalizePartial (tested indirectly)", () => {
    it("normalizes partial through setAgentConnected - converts charsEnd to charsReceived", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        partial: {
          index: 2,
          role: "assistant",
          content: "Hello",
          charsEnd: 5,
        },
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.charsReceived).toBe(5);
      expect(partial.charsEnd).toBeUndefined();
    });

    it("handles null partial through setAgentConnected", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        partial: null,
      });

      expect(useStore.getState().agentsCache["agent-1"].partial).toBeNull();
    });

    it("normalizes partial through syncAgentMessages", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().syncAgentMessages("agent-1", {
        partial: {
          index: 5,
          content: "Synced",
          charsEnd: 6,
        },
        messageCount: 4,
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.charsReceived).toBe(6);
    });
  });

  describe("addUserMessage with existing cache", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("adds user message and creates partial for assistant response", () => {
      useStore.getState().addUserMessage("agent-1", "Hello");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(1);
      expect(cache.messages[0]).toMatchObject({
        index: 0,
        role: "user",
        content: "Hello",
      });
      expect(cache.lastIndex).toBe(0);
      expect(cache.partial).toMatchObject({
        index: 1,
        role: "assistant",
        content: "",
        charsReceived: 0,
      });
    });
  });

  describe("clearPartial with existing cache", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("clears the partial message", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 5,
        content: "Streaming...",
        charsReceived: 12,
      };

      useStore.getState().clearPartial("agent-1");

      expect(useStore.getState().agentsCache["agent-1"].partial).toBeNull();
    });
  });

  describe("setWaitingForResponse with existing cache", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("sets waiting flag on existing cache", () => {
      useStore.getState().setWaitingForResponse("agent-1", true);

      expect(
        useStore.getState().agentsCache["agent-1"].waitingForResponse,
      ).toBe(true);

      useStore.getState().setWaitingForResponse("agent-1", false);

      expect(
        useStore.getState().agentsCache["agent-1"].waitingForResponse,
      ).toBe(false);
    });
  });

  describe("syncAgentMessages with existing cache", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("merges messages and updates status", () => {
      useStore.getState().agentsCache["agent-1"].messages = [
        { index: 0, role: "user", content: "Existing" },
      ];

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [{ index: 1, role: "assistant", content: "New" }],
        partial: { index: 2, content: "Partial", charsEnd: 7 },
        status: "streaming",
        messageCount: 1,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(2);
      expect(cache.messages[1].content).toBe("New");
      expect(cache.status).toBe("streaming");
      expect(cache.lastIndex).toBe(1);
    });

    it("preserves existing messages when syncing duplicates", () => {
      useStore.getState().agentsCache["agent-1"].messages = [
        { index: 0, role: "user", content: "Existing" },
      ];

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [
          { index: 0, role: "user", content: "Duplicate" },
          { index: 1, role: "assistant", content: "New" },
        ],
        messageCount: 1,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(2);
      // Should keep original message at index 0
      expect(cache.messages[0].content).toBe("Existing");
    });

    it("handles sync when cache has no messages array", () => {
      // Clear messages to test the || [] branch
      useStore.getState().agentsCache["agent-1"].messages = undefined;

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [{ index: 0, role: "user", content: "New" }],
        messageCount: 0,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(1);
    });

    it("recalculates lastIndex from messages when sync returns empty", () => {
      useStore.getState().agentsCache["agent-1"].lastIndex = 5;
      // Add a message so lastIndex would be recalculated
      useStore.getState().agentsCache["agent-1"].messages = [{ index: 5 }];

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [],
        // No messageCount provided
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.lastIndex).toBe(5);
    });

    it("handles partial with undefined charsEnd in syncAgentMessages", () => {
      useStore.getState().syncAgentMessages("agent-1", {
        partial: {
          index: 5,
          content: "Test",
          // charsEnd is undefined
        },
        messageCount: 0,
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.charsReceived).toBe(0);
    });

    it("handles partial with nullish charsEnd in setAgentConnected", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        partial: {
          index: 0,
          content: "Test",
          // charsEnd is undefined
        },
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.charsReceived).toBe(0);
    });
  });

  describe("setAgentDisconnected with existing cache", () => {
    it("updates status to disconnected when cache exists", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      useStore.getState().setAgentDisconnected("agent-1");

      expect(useStore.getState().agentsCache["agent-1"].status).toBe(
        "disconnected",
      );
    });
  });

  describe("simple setters", () => {
    it("setIsConnected updates connection status", () => {
      useStore.getState().setIsConnected(true);
      expect(useStore.getState().isConnected).toBe(true);

      useStore.getState().setIsConnected(false);
      expect(useStore.getState().isConnected).toBe(false);
    });

    it("setAgents updates agents list", () => {
      useStore.getState().setAgents([{ id: "agent-1", model: "gpt-4" }]);
      expect(useStore.getState().agents).toHaveLength(1);
    });

    it("setModels updates models list", () => {
      useStore.getState().setModels([{ name: "gpt-4", provider: "openai" }]);
      expect(useStore.getState().models).toHaveLength(1);
    });
  });
});
