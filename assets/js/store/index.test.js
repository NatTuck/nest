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

      // Verify no changes after all operations
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

    it("stores modes, defaultMode, and currentMode from the init payload", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        modes: ["chat", "build", "plan"],
        defaultMode: "build",
        currentMode: "build",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.modes).toEqual(["chat", "build", "plan"]);
      expect(cache.defaultMode).toBe("build");
      expect(cache.currentMode).toBe("build");
    });

    it("initializes mode fields to null when payload omits them and no existing cache", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.modes).toBeNull();
      expect(cache.defaultMode).toBeNull();
      expect(cache.currentMode).toBeNull();
    });

    it("preserves existing mode values when a rejoin payload omits them", () => {
      // Initial connection with full mode info
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        modes: ["chat", "build"],
        defaultMode: "build",
        currentMode: "build",
      });

      // Mid-stream rejoin (e.g. via chat:status) — payload has no modes
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 2,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.modes).toEqual(["chat", "build"]);
      expect(cache.defaultMode).toBe("build");
      expect(cache.currentMode).toBe("build");
    });

    it("overrides existing mode values when a new payload provides them", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        modes: ["chat", "build"],
        defaultMode: "build",
        currentMode: "build",
      });

      // A later init (e.g. after mode switch) replaces the values
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 4,
        modes: ["chat", "build", "plan"],
        defaultMode: "plan",
        currentMode: "plan",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.modes).toEqual(["chat", "build", "plan"]);
      expect(cache.defaultMode).toBe("plan");
      expect(cache.currentMode).toBe("plan");
    });

    it("stores initial agentState from payload.status", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "streaming",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("streaming");
    });

    it("defaults agentState to 'idle' when payload has no status", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("idle");
    });
  });

  describe("setAgentState", () => {
    it("updates agentState for existing agent", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      useStore.getState().setAgentState("agent-1", "streaming");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("streaming");
    });

    it("does nothing for non-existent agent", () => {
      const initialCache = useStore.getState().agentsCache;

      useStore.getState().setAgentState("non-existent", "streaming");

      expect(useStore.getState().agentsCache).toBe(initialCache);
    });

    it("updates through all status transitions", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      useStore.getState().setAgentState("agent-1", "streaming");
      expect(useStore.getState().agentsCache["agent-1"].agentState).toBe(
        "streaming",
      );

      useStore.getState().setAgentState("agent-1", "executing_tools");
      expect(useStore.getState().agentsCache["agent-1"].agentState).toBe(
        "executing_tools",
      );

      useStore.getState().setAgentState("agent-1", "streaming");
      expect(useStore.getState().agentsCache["agent-1"].agentState).toBe(
        "streaming",
      );

      useStore.getState().setAgentState("agent-1", "idle");
      expect(useStore.getState().agentsCache["agent-1"].agentState).toBe(
        "idle",
      );
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

  describe("setNotification and clearNotification", () => {
    it("sets notification for existing agent", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      useStore.getState().setNotification("agent-1", {
        type: "max_iterations",
        message: "Max tool iterations reached",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.notification).toEqual({
        type: "max_iterations",
        message: "Max tool iterations reached",
      });
    });

    it("does nothing for non-existent agent", () => {
      const initialCache = useStore.getState().agentsCache;

      useStore.getState().setNotification("non-existent", {
        type: "max_iterations",
        message: "test",
      });

      expect(useStore.getState().agentsCache).toBe(initialCache);
    });

    it("clears notification for existing agent", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      useStore.getState().setNotification("agent-1", {
        type: "max_iterations",
        message: "Max tool iterations reached",
      });

      expect(
        useStore.getState().agentsCache["agent-1"].notification,
      ).not.toBeNull();

      useStore.getState().clearNotification("agent-1");

      expect(
        useStore.getState().agentsCache["agent-1"].notification,
      ).toBeNull();
    });

    it("does nothing when clearing for non-existent agent", () => {
      const initialCache = useStore.getState().agentsCache;

      useStore.getState().clearNotification("non-existent");

      expect(useStore.getState().agentsCache).toBe(initialCache);
    });

    it("clears notification when user sends a message", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      useStore.getState().setNotification("agent-1", {
        type: "max_iterations",
        message: "Max tool iterations reached",
      });

      expect(
        useStore.getState().agentsCache["agent-1"].notification,
      ).not.toBeNull();

      useStore.getState().addUserMessage("agent-1", "New message");

      expect(
        useStore.getState().agentsCache["agent-1"].notification,
      ).toBeNull();
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

  describe("addChatDelta with deltaIndex (new protocol)", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("applies first delta with deltaIndex 0", () => {
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Hello",
        partType: "text",
      });

      expect(result).toEqual({ applied: true, needsSync: false });
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.content).toBe("Hello");
      expect(cache.streaming.nextDeltaIndex).toBe(1);
      expect(cache.streaming.messageIndex).toBe(5);
    });

    it("applies sequential deltas", () => {
      // First delta
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Hello ",
        partType: "text",
      });

      // Second delta
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 1,
        content: "world",
        partType: "text",
      });

      expect(result).toEqual({ applied: true, needsSync: false });
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.content).toBe("Hello world");
      expect(cache.streaming.nextDeltaIndex).toBe(2);
    });

    it("detects duplicate delta and rejects without sync", () => {
      // Apply first delta
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Hello",
        partType: "text",
      });

      // Try to apply same delta again
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Duplicate",
        partType: "text",
      });

      expect(result).toEqual({
        applied: false,
        needsSync: false,
        outOfOrder: false,
      });
      // Content should not change
      expect(useStore.getState().agentsCache["agent-1"].streaming.content).toBe(
        "Hello",
      );
    });

    it("detects out-of-order delta and requests sync", () => {
      // Apply first delta
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "First",
        partType: "text",
      });

      // Try to apply delta with index 2 (skipping index 1)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 2,
        content: "Third",
        partType: "text",
      });

      expect(result).toEqual({
        applied: false,
        needsSync: true,
        outOfOrder: true,
      });
      // Content should not change
      expect(useStore.getState().agentsCache["agent-1"].streaming.content).toBe(
        "First",
      );
    });

    it("resets streaming state when message index changes", () => {
      // Apply delta for message 5
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Message 5",
        partType: "text",
      });

      // Apply delta for message 6 - should reset streaming
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 6,
        deltaIndex: 0,
        content: "Message 6",
        partType: "text",
      });

      expect(result).toEqual({ applied: true, needsSync: false });
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.messageIndex).toBe(6);
      expect(cache.streaming.content).toBe("Message 6");
      expect(cache.streaming.nextDeltaIndex).toBe(1);
    });

    it("stores tool call information in streaming state", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: ' {"key": "value"}',
        partType: "tool_arguments",
        toolCallId: "call-123",
        toolCallName: "test_tool",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.toolCallId).toBe("call-123");
      expect(cache.streaming.toolCallName).toBe("test_tool");
    });

    it("preserves existing tool call info when new delta has none", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Start",
        partType: "text",
        toolCallId: "call-123",
        toolCallName: "test_tool",
      });

      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 1,
        content: " end",
        partType: "text",
        // No tool call info - should preserve existing
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.toolCallId).toBe("call-123");
      expect(cache.streaming.toolCallName).toBe("test_tool");
    });

    it("sets waitingForResponse to false when applying delta", () => {
      useStore.getState().agentsCache["agent-1"].waitingForResponse = true;

      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Response",
        partType: "text",
      });

      expect(
        useStore.getState().agentsCache["agent-1"].waitingForResponse,
      ).toBe(false);
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

    it("preserves existing apiLogs when updating message", () => {
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello",
        apiLogs: [
          {
            id: "000.000",
            type: "request",
            timestamp: "2024-01-01T00:00:00Z",
            payload: {},
          },
        ],
      });

      // Update the message without apiLogs
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello world",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].content).toBe("Hello world");
      expect(messages[0].apiLogs).toHaveLength(1);
      expect(messages[0].apiLogs[0].id).toBe("000.000");
    });

    it("uses new apiLogs when updating message with apiLogs", () => {
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello",
        apiLogs: [
          {
            id: "000.000",
            type: "request",
            timestamp: "2024-01-01T00:00:00Z",
            payload: {},
          },
        ],
      });

      // Update with new apiLogs
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello world",
        apiLogs: [
          {
            id: "000.000",
            type: "request",
            timestamp: "2024-01-01T00:00:00Z",
            payload: {},
          },
          {
            id: "001.001",
            type: "response",
            timestamp: "2024-01-01T00:00:01Z",
            payload: {},
          },
        ],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].apiLogs).toHaveLength(2);
      expect(messages[0].apiLogs[1].id).toBe("001.001");
    });

    it("handles message update without existing or new apiLogs", () => {
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello",
      });

      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Hello world",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].content).toBe("Hello world");
      expect(messages[0].apiLogs).toEqual([]);
    });

    it("preserves toolCalls when updating existing message", () => {
      // Add initial message with toolCalls
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Let me help",
        toolCalls: [
          {
            id: "call_123",
            name: "shell_cmd",
            arguments: { command: "ls" },
          },
        ],
      });

      // Update the message without toolCalls (simulating a sync)
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Let me help",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].toolCalls).toHaveLength(1);
      expect(messages[0].toolCalls[0].id).toBe("call_123");
    });

    it("preserves toolResults when updating existing message", () => {
      // Add initial message with toolResults
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "tool",
        content: "Tool result",
        toolResults: [
          {
            tool_call_id: "call_123",
            name: "shell_cmd",
            content: "file1.txt file2.txt",
            is_error: false,
          },
        ],
      });

      // Update the message without toolResults (simulating a sync)
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "tool",
        content: "Tool result",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].toolResults).toHaveLength(1);
      expect(messages[0].toolResults[0].tool_call_id).toBe("call_123");
    });
  });

  describe("setWaitingForResponse during tool execution", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("should set waitingForResponse when status changes to executing_tools", () => {
      // Setup: User sends a message
      useStore.getState().addUserMessage("agent-1", "Run a command");
      expect(
        useStore.getState().agentsCache["agent-1"].waitingForResponse,
      ).toBe(true);

      // Simulate receiving tool call message (assistant with tool_calls)
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "",
        toolCalls: [
          {
            id: "call_123",
            name: "shell_cmd",
            arguments: { command: "ls" },
          },
        ],
      });

      // At this point, waitingForResponse should still be true
      // because we're waiting for tool execution
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.waitingForResponse).toBe(true);
    });

    it("should preserve waitingForResponse when adding tool result message", () => {
      // Setup: User message and tool call
      useStore.getState().addUserMessage("agent-1", "Run a command");
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "",
        toolCalls: [{ id: "call_123", name: "shell_cmd", arguments: {} }],
      });

      // Simulate receiving tool result
      useStore.getState().addChatMessage("agent-1", {
        index: 2,
        role: "tool",
        content: "output",
        toolResults: [
          {
            tool_call_id: "call_123",
            name: "shell_cmd",
            content: "output",
            is_error: false,
          },
        ],
      });

      // After tool result, waitingForResponse should remain true
      // until we receive the final assistant response
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.waitingForResponse).toBe(true);
    });

    it("should clear waitingForResponse when a terminal chat:error fires (max iterations reached)", () => {
      // Setup: User message, tool call, tool result
      useStore.getState().addUserMessage("agent-1", "Run a command");
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "",
        toolCalls: [{ id: "call_123", name: "shell_cmd", arguments: {} }],
      });
      useStore.getState().addChatMessage("agent-1", {
        index: 2,
        role: "tool",
        content: "output",
        toolResults: [
          {
            tool_call_id: "call_123",
            name: "shell_cmd",
            content: "output",
            is_error: false,
          },
        ],
      });

      // Mid-iteration: partial is set, waiting is still true
      useStore.getState().addChatDelta("agent-1", {
        index: 3,
        content: "Let me try",
        charsStart: 0,
        charsEnd: 11,
      });

      let cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.waitingForResponse).toBe(false);
      expect(cache.partial).not.toBeNull();

      // The agent loop hits the max-iterations cap and the channel handler
      // runs the chat:error path: setAgentError + clearPartial +
      // setWaitingForResponse(false).
      useStore
        .getState()
        .setAgentError("agent-1", 'Error: "Max tool iterations reached"');
      useStore.getState().clearPartial("agent-1");
      useStore.getState().setWaitingForResponse("agent-1", false);

      cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.waitingForResponse).toBe(false);
      expect(cache.status).toBe("error");
      expect(cache.error).toBe('Error: "Max tool iterations reached"');
      expect(cache.partial).toBeNull();
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

  describe("clearStreaming with existing cache", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
    });

    it("clears the streaming state", () => {
      useStore.getState().agentsCache["agent-1"].streaming = {
        messageIndex: 5,
        nextDeltaIndex: 3,
        content: "Streaming...",
      };

      useStore.getState().clearStreaming("agent-1");

      expect(useStore.getState().agentsCache["agent-1"].streaming).toBeNull();
      expect(useStore.getState().agentsCache["agent-1"].partial).toBeNull();
    });
  });

  describe("addChatDelta with different part types", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("creates new segment when part type changes", () => {
      // First delta with text type
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 0,
        content: "Hello ",
        partType: "text",
      });

      // Second delta with tool_arguments type - should create new segment
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        deltaIndex: 1,
        content: '{"key": "val"}',
        partType: "tool_arguments",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming.segments).toHaveLength(2);
      expect(cache.streaming.segments[0]).toMatchObject({
        type: "text",
        content: "Hello ",
      });
      expect(cache.streaming.segments[1]).toMatchObject({
        type: "tool_arguments",
        content: '{"key": "val"}',
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

    it("merges messages and updates agentState", () => {
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
      expect(cache.status).toBe("connected");
      expect(cache.agentState).toBe("streaming");
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

  describe("tool call message flow", () => {
    it("handles complete tool call flow with four separate messages", () => {
      // Setup agent
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      // Message 0: User message
      useStore.getState().addUserMessage("agent-1", "List the files");

      // Message 1: Assistant with tool calls
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "I'll run that command for you",
        toolCalls: [
          {
            id: "call_123",
            name: "shell_cmd",
            arguments: { command: "ls -la" },
          },
        ],
      });

      // Message 2: Tool result
      useStore.getState().addChatMessage("agent-1", {
        index: 2,
        role: "tool",
        content: "",
        toolResults: [
          {
            tool_call_id: "call_123",
            name: "shell_cmd",
            content: "total 4\\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
            is_error: false,
          },
        ],
      });

      // Message 3: Final assistant response
      useStore.getState().addChatMessage("agent-1", {
        index: 3,
        role: "assistant",
        content: "Here are the directory contents",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;

      // Verify 4 separate messages
      expect(messages).toHaveLength(4);

      // Verify each message has correct role and index
      expect(messages[0]).toMatchObject({
        index: 0,
        role: "user",
        content: "List the files",
      });

      expect(messages[1]).toMatchObject({
        index: 1,
        role: "assistant",
        content: "I'll run that command for you",
      });
      expect(messages[1].toolCalls).toHaveLength(1);
      expect(messages[1].toolCalls[0].id).toBe("call_123");

      expect(messages[2]).toMatchObject({
        index: 2,
        role: "tool",
      });
      expect(messages[2].toolResults).toHaveLength(1);
      expect(messages[2].toolResults[0].tool_call_id).toBe("call_123");

      expect(messages[3]).toMatchObject({
        index: 3,
        role: "assistant",
        content: "Here are the directory contents",
      });
    });

    it("separates assistant message with toolCalls from tool result message", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      // Add assistant message with tool calls
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Let me calculate that",
        toolCalls: [
          {
            id: "call_456",
            name: "calculator",
            arguments: { expression: "2 + 2" },
          },
        ],
      });

      // Add separate tool result message
      useStore.getState().addChatMessage("agent-1", {
        index: 2,
        role: "tool",
        content: "",
        toolResults: [
          {
            tool_call_id: "call_456",
            name: "calculator",
            content: "4",
            is_error: false,
          },
        ],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;

      // Should have exactly 2 messages, not merged
      expect(messages).toHaveLength(2);

      // First message is assistant with toolCalls
      expect(messages[0].role).toBe("assistant");
      expect(messages[0].toolCalls).toBeDefined();
      expect(messages[0].toolCalls[0].name).toBe("calculator");

      // Second message is tool result (different role)
      expect(messages[1].role).toBe("tool");
      expect(messages[1].toolResults).toBeDefined();
      expect(messages[1].toolResults[0].content).toBe("4");
    });

    it("maintains message order as received in tool call flow", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      // Add messages out of order to test append behavior
      useStore.getState().addChatMessage("agent-1", {
        index: 2,
        role: "tool",
        content: "",
        toolResults: [
          {
            tool_call_id: "call_789",
            name: "weather",
            content: "sunny",
            is_error: false,
          },
        ],
      });

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Checking weather",
        toolCalls: [
          { id: "call_789", name: "weather", arguments: { city: "London" } },
        ],
      });

      useStore.getState().addChatMessage("agent-1", {
        index: 3,
        role: "assistant",
        content: "It's sunny today",
      });

      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        content: "What's the weather?",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;

      // Messages are appended in received order, not sorted by index
      expect(messages).toHaveLength(4);
      expect(messages[0].index).toBe(2);
      expect(messages[0].role).toBe("tool");

      expect(messages[1].index).toBe(1);
      expect(messages[1].role).toBe("assistant");

      expect(messages[2].index).toBe(3);
      expect(messages[2].role).toBe("assistant");

      expect(messages[3].index).toBe(0);
      expect(messages[3].role).toBe("user");

      // But each message has correct content
      expect(messages[0].toolResults[0].content).toBe("sunny");
      expect(messages[1].toolCalls[0].name).toBe("weather");
      expect(messages[2].content).toBe("It's sunny today");
      expect(messages[3].content).toBe("What's the weather?");
    });
  });

  describe("context window fields", () => {
    it("setAgentConnecting initializes contextLimit and source to null", () => {
      useStore.getState().setAgentConnecting("agent-1");
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBeNull();
      expect(cache.contextLimitSource).toBeNull();
      expect(cache.usage).toBeNull();
    });

    it("setAgentConnected stores contextLimit, contextLimitSource, and usage from the init payload", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        contextLimit: 128000,
        contextLimitSource: "openrouter",
        usage: {
          input_tokens: 1234,
          output_tokens: 56,
          total_tokens: 1290,
          reasoning_tokens: 0,
          last_output: 56,
        },
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(128000);
      expect(cache.contextLimitSource).toBe("openrouter");
      expect(cache.usage).toEqual({
        input_tokens: 1234,
        output_tokens: 56,
        total_tokens: 1290,
        reasoning_tokens: 0,
        last_output: 56,
      });
    });

    it("preserves existing contextLimit when a rejoin payload omits it", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        contextLimit: 128000,
        contextLimitSource: "config",
      });

      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 4,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(128000);
      expect(cache.contextLimitSource).toBe("config");
    });

    it("overrides existing contextLimit when a new payload provides it", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        contextLimit: 128000,
        contextLimitSource: "default",
      });

      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 2,
        contextLimit: 32768,
        contextLimitSource: "vllm",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(32768);
      expect(cache.contextLimitSource).toBe("vllm");
    });
  });

  describe("setAgentState with extra fields (chat:status payload)", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("updates contextLimit and source from a status push", () => {
      useStore.getState().setAgentState("agent-1", "streaming", {
        contextLimit: 200000,
        contextLimitSource: "openrouter",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("streaming");
      expect(cache.contextLimit).toBe(200000);
      expect(cache.contextLimitSource).toBe("openrouter");
    });

    it("updates usage from a status push", () => {
      useStore.getState().setAgentState("agent-1", "streaming", {
        usage: {
          input_tokens: 5000,
          output_tokens: 250,
          total_tokens: 5250,
          reasoning_tokens: 0,
          last_output: 250,
        },
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.usage.input_tokens).toBe(5000);
      expect(cache.usage.output_tokens).toBe(250);
    });

    it("does not clobber existing contextLimit when the extra arg omits it", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        contextLimit: 128000,
        contextLimitSource: "config",
      });

      // A status push that doesn't carry contextLimit fields.
      useStore.getState().setAgentState("agent-1", "streaming", {
        usage: { input_tokens: 100, output_tokens: 50, total_tokens: 150 },
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(128000);
      expect(cache.contextLimitSource).toBe("config");
      expect(cache.usage.input_tokens).toBe(100);
    });
  });

  describe("setAgentContextLimit and setAgentUsage", () => {
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        contextLimit: 128000,
        contextLimitSource: "default",
      });
    });

    it("setAgentContextLimit updates just the limit and source", () => {
      useStore.getState().setAgentContextLimit("agent-1", 32768, "vllm");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(32768);
      expect(cache.contextLimitSource).toBe("vllm");
    });

    it("setAgentContextLimit preserves the source when called with undefined", () => {
      useStore.getState().setAgentContextLimit("agent-1", 999999);

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.contextLimit).toBe(999999);
      expect(cache.contextLimitSource).toBe("default");
    });

    it("setAgentContextLimit is a no-op for an unknown agent", () => {
      const before = useStore.getState().agentsCache;
      useStore.getState().setAgentContextLimit("missing", 1234, "vllm");
      expect(useStore.getState().agentsCache).toBe(before);
    });

    it("setAgentUsage updates the usage map", () => {
      useStore.getState().setAgentUsage("agent-1", {
        input_tokens: 1000,
        output_tokens: 100,
        total_tokens: 1100,
        reasoning_tokens: 0,
        last_output: 100,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.usage.input_tokens).toBe(1000);
    });

    it("setAgentUsage is a no-op for null usage", () => {
      const before = useStore.getState().agentsCache["agent-1"].usage;
      useStore.getState().setAgentUsage("agent-1", null);
      expect(useStore.getState().agentsCache["agent-1"].usage).toBe(before);
    });

    it("setAgentUsage is a no-op for an unknown agent", () => {
      const before = useStore.getState().agentsCache;
      useStore.getState().setAgentUsage("missing", { input_tokens: 1 });
      expect(useStore.getState().agentsCache).toBe(before);
    });
  });

  describe("compaction history", () => {
    it("setAgentConnected stores history from the init payload", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [
          {
            index: 0,
            role: "compaction",
            archivedCount: 5,
            occurredAt: "2024-01-01T00:00:00Z",
            apiLogs: [],
          },
        ],
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.history).toEqual([
        {
          index: 0,
          role: "compaction",
          archivedCount: 5,
          occurredAt: "2024-01-01T00:00:00Z",
          apiLogs: [],
        },
      ]);
    });

    it("setAgentConnected initializes history to [] when omitted", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      expect(useStore.getState().agentsCache["agent-1"].history).toEqual([]);
    });

    it("syncAgentMessages preserves history when payload has none", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [{ index: 0, role: "compaction", archivedCount: 5 }],
      });

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [{ index: 0, role: "user", content: "Hi" }],
        messageCount: 1,
      });

      expect(useStore.getState().agentsCache["agent-1"].history).toEqual([
        { index: 0, role: "compaction", archivedCount: 5 },
      ]);
    });

    it("syncAgentMessages replaces history when payload provides new", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [{ index: 0, role: "compaction", archivedCount: 5 }],
      });

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [],
        history: [
          { index: 0, role: "compaction", archivedCount: 5 },
          { index: 1, role: "user", content: "Old message" },
          { index: 2, role: "compaction", archivedCount: 3 },
        ],
        messageCount: 0,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.history).toHaveLength(3);
      expect(cache.history[0].role).toBe("compaction");
      expect(cache.history[2].role).toBe("compaction");
    });
  });

  describe("setAgentHistory (chat:compaction handler)", () => {
    it("replaces history with the broadcast's history list", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [{ index: 0, role: "compaction", archivedCount: 1 }],
      });

      useStore.getState().setAgentHistory("agent-1", [
        { index: 0, role: "user", content: "Old A" },
        { index: 1, role: "assistant", content: "Old B" },
        { index: 2, role: "compaction", archivedCount: 2 },
      ]);

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.history).toHaveLength(3);
      expect(cache.history[0].content).toBe("Old A");
      expect(cache.history[2].role).toBe("compaction");
    });

    it("appends the explicit marker when history has no compaction role", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [],
      });

      useStore
        .getState()
        .setAgentHistory(
          "agent-1",
          [{ index: 0, role: "user", content: "old" }],
          { index: 1, role: "compaction", archivedCount: 1 },
        );

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.history).toHaveLength(2);
      expect(cache.history[1].role).toBe("compaction");
    });

    it("does not duplicate the marker when history already has one", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [],
      });

      useStore.getState().setAgentHistory(
        "agent-1",
        [
          { index: 0, role: "user", content: "old" },
          { index: 1, role: "compaction", archivedCount: 1 },
        ],
        { index: 1, role: "compaction", archivedCount: 1 },
      );

      const cache = useStore.getState().agentsCache["agent-1"];
      const compactionCount = cache.history.filter(
        (m) => m.role === "compaction",
      ).length;
      expect(compactionCount).toBe(1);
    });

    it("ignores non-array history payloads", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        history: [{ index: 0, role: "user", content: "kept" }],
      });

      const before = useStore.getState().agentsCache["agent-1"];
      useStore.getState().setAgentHistory("agent-1", null, null);
      const after = useStore.getState().agentsCache["agent-1"];

      expect(after).toBe(before);
    });

    it("is a no-op for an unknown agent", () => {
      const before = useStore.getState().agentsCache;
      useStore.getState().setAgentHistory("missing", [], null);
      expect(useStore.getState().agentsCache).toBe(before);
    });
  });
});
