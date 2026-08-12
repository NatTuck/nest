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

  describe("clearAgentError", () => {
    it("clears the chat-task error and promotes status to connected when agentState is idle", () => {
      // Recovery scenario from the user's report: the LLM call
      // crashed (`chat:error`) AND the agent's GenServer already
      // landed on `:idle` (companion `chat:status: idle`). The
      // channel is alive; dismissing the error locally should
      // restore the textarea without forcing a full page reload.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", { status: "idle" });
      useStore.getState().setAgentError("agent-1", "Model unavailable");

      let cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.status).toBe("error");
      expect(cache.error).toBe("Model unavailable");
      expect(cache.agentState).toBe("idle");

      useStore.getState().clearAgentError("agent-1");

      cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.error).toBeNull();
      expect(cache.status).toBe("connected");
      expect(cache.agentState).toBe("idle");
    });

    it("leaves status alone when agentState is null (channel-join failure path)", () => {
      // For genuine channel-join failures, agentState was never
      // set to "idle" — the channel itself is the problem. The
      // user must Retry (which re-joins). Dismiss clears the
      // error message but keeps status at "error".
      useStore.getState().setAgentError("new-agent", "Failed to connect");

      useStore.getState().clearAgentError("new-agent");

      const cache = useStore.getState().agentsCache["new-agent"];
      expect(cache.error).toBeNull();
      expect(cache.status).toBe("error");
    });

    it("does not touch status when status is not error (defensive)", () => {
      // If `cache.status` is "connected" already (e.g. the
      // error/event sequence arrived out of order), clearAgentError
      // must not flip status — it just clears the error field.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", { status: "idle" });
      useStore.getState().agentsCache["agent-1"].error = "stale";

      useStore.getState().clearAgentError("agent-1");

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.error).toBeNull();
      expect(cache.status).toBe("connected");
    });

    it("is a no-op when the agent cache does not exist", () => {
      // Calling clearAgentError on an unknown agent returns the
      // existing state unchanged (no throw, no creation).
      const before = useStore.getState().agentsCache;
      useStore.getState().clearAgentError("missing-agent");
      expect(useStore.getState().agentsCache).toBe(before);
    });
  });

  describe("setCompactionError", () => {
    it("sets compactionError on existing cache", () => {
      useStore.getState().setAgentConnecting("agent-1");

      useStore
        .getState()
        .setCompactionError(
          "agent-1",
          "Compaction failed: LLM returned empty summary.",
        );

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.compactionError).toBe(
        "Compaction failed: LLM returned empty summary.",
      );
    });

    it("is a no-op when the agent isn't in the cache", () => {
      const before = useStore.getState().agentsCache;
      useStore.getState().setCompactionError("missing-agent", "msg");
      expect(useStore.getState().agentsCache).toBe(before);
    });
  });

  describe("clearCompactionError", () => {
    it("clears compactionError from the cache", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setCompactionError("agent-1", "msg");

      useStore.getState().clearCompactionError("agent-1");

      expect(
        useStore.getState().agentsCache["agent-1"].compactionError,
      ).toBeNull();
    });

    it("is a no-op when the agent isn't in the cache", () => {
      const before = useStore.getState().agentsCache;
      useStore.getState().clearCompactionError("missing-agent");
      expect(useStore.getState().agentsCache).toBe(before);
    });
  });

  describe("setAgentState compaction-failure clearing", () => {
    it("clears compactionError when agentState transitions out of compaction_failed", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentState("agent-1", "compaction_failed");
      useStore.getState().setCompactionError("agent-1", "old error");

      // Simulate the user clicking Retry: the agent transitions
      // back to :compacting and the stale error text should clear.
      useStore.getState().setAgentState("agent-1", "compacting");

      expect(
        useStore.getState().agentsCache["agent-1"].compactionError,
      ).toBeNull();
    });

    it("preserves compactionError when agentState stays at compaction_failed", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentState("agent-1", "compaction_failed");
      useStore.getState().setCompactionError("agent-1", "preserved");

      useStore.getState().setAgentState("agent-1", "compaction_failed");

      expect(useStore.getState().agentsCache["agent-1"].compactionError).toBe(
        "preserved",
      );
    });
  });

  describe("setCompactionLoop", () => {
    it("sets the compactionLoop banner data on an existing agent", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });

      const loopInfo = {
        content: "compaction isn't reducing the conversation",
        attemptCount: 3,
        maxAttempts: 3,
      };
      useStore.getState().setCompactionLoop("agent-1", loopInfo);

      expect(useStore.getState().agentsCache["agent-1"].compactionLoop).toEqual(
        loopInfo,
      );
    });

    it("no-ops on missing agent", () => {
      expect(() =>
        useStore
          .getState()
          .setCompactionLoop("missing-agent", { content: "m" }),
      ).not.toThrow();

      expect(useStore.getState().agentsCache["missing-agent"]).toBeUndefined();
    });
  });

  describe("clearCompactionLoop", () => {
    it("clears the compactionLoop text", () => {
      useStore.getState().setAgentConnected("agent-1", {
        messageCount: 0,
        status: "idle",
      });
      useStore.getState().setCompactionLoop("agent-1", { content: "msg" });

      useStore.getState().clearCompactionLoop("agent-1");

      expect(useStore.getState().agentsCache["agent-1"].compactionLoop).toBe(
        null,
      );
    });
  });

  describe("setAgentState compaction-loop clearing", () => {
    it("clears compactionLoop when agentState transitions out of compaction_loop_detected", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentState("agent-1", "compaction_loop_detected");
      useStore.getState().setCompactionLoop("agent-1", "loop error");

      // Simulate the user clicking OK: the agent transitions back
      // to :idle and the loop-error text should clear.
      useStore.getState().setAgentState("agent-1", "idle");

      expect(
        useStore.getState().agentsCache["agent-1"].compactionLoop,
      ).toBeNull();
    });

    it("preserves compactionLoop when agentState stays at compaction_loop_detected", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentState("agent-1", "compaction_loop_detected");
      useStore.getState().setCompactionLoop("agent-1", "loop error");

      useStore.getState().setAgentState("agent-1", "compaction_loop_detected");

      expect(useStore.getState().agentsCache["agent-1"].compactionLoop).toBe(
        "loop error",
      );
    });

    it("clears both compactionError AND compactionLoop on transition out of either state", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentState("agent-1", "compaction_failed");
      useStore.getState().setCompactionError("agent-1", "first error");

      // Transition to a fresh loop-detected state — old error text clears.
      useStore.getState().setAgentState("agent-1", "compaction_loop_detected");

      expect(
        useStore.getState().agentsCache["agent-1"].compactionError,
      ).toBeNull();
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
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].partial.parts.filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello 💡 world");
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
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].partial.parts.filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello 💡🎉! more");
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
      expect(
        cache.streaming.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello");
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
      expect(
        cache.streaming.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello world");
      expect(cache.streaming.nextDeltaIndex).toBe(2);
    });

    it("detects duplicate delta and rejects without sync", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

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

      // Duplicate detection warns with the per-agent prefix and the
      // index mismatch payload (expectedDeltaIndex=1 from the first
      // accepted delta, receivedDeltaIndex=0 for the duplicate).
      expect(warnSpy).toHaveBeenCalledWith(
        "[agent:agent-1] Delta duplicate:",
        expect.objectContaining({
          messageIndex: 5,
          expectedDeltaIndex: 1,
          receivedDeltaIndex: 0,
        }),
      );

      // Content should not change
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].streaming.parts.filter(
            (p) => p.kind === "text",
          )
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello");

      warnSpy.mockRestore();
    });

    it("detects out-of-order delta and requests sync", () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

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

      // Out-of-order detection warns with the corresponding payload.
      expect(warnSpy).toHaveBeenCalledWith(
        "[agent:agent-1] Delta out of order:",
        expect.objectContaining({
          messageIndex: 5,
          expectedDeltaIndex: 1,
          receivedDeltaIndex: 2,
        }),
      );

      // Content should not change
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].streaming.parts.filter(
            (p) => p.kind === "text",
          )
          .map((p) => p.text || "")
          .join(""),
      ).toBe("First");

      warnSpy.mockRestore();
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
      expect(
        cache.streaming.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Message 6");
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
      expect(
        partial.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello world");
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
      expect(
        partial.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("New content");
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
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].partial.parts.filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello");
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
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].partial.parts.filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello world");
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
      expect(
        useStore
          .getState()
          .agentsCache["agent-1"].partial.parts.filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Hello world");
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

      // Add message with no content and no parts — the new
      // store derives `content` from `parts` and defaults to "".
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: null,
        parts: null,
      });

      // Should complete without errors and the content
      // field on the merged message defaults to "".
      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].content).toBe("");

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
      // Add initial message with tool calls as parts (the new
      // canonical wire format). Legacy `toolCalls` is also
      // provided to verify the store derives it from parts.
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Let me help",
        parts: [
          { kind: "text", text: "Let me help" },
          {
            kind: "tool_use",
            id: "call_123",
            name: "shell_cmd",
            arguments: { command: "ls" },
          },
        ],
        toolCalls: [
          {
            id: "call_123",
            name: "shell_cmd",
            arguments: { command: "ls" },
          },
        ],
      });

      // Update the message without tool calls (simulating a sync)
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "assistant",
        content: "Let me help",
        parts: [{ kind: "text", text: "Let me help" }],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].toolCalls).toHaveLength(1);
      expect(messages[0].toolCalls[0].id).toBe("call_123");
    });

    it("preserves toolResults when updating existing message", () => {
      // Add initial message with tool results as parts (the new
      // canonical wire format). Legacy `toolResults` is also
      // provided to verify the store derives it from parts.
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "tool",
        content: "Tool result",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "call_123",
            name: "shell_cmd",
            content: "file1.txt file2.txt",
            isError: false,
          },
        ],
        toolResults: [
          {
            tool_call_id: "call_123",
            name: "shell_cmd",
            content: "file1.txt file2.txt",
            is_error: false,
          },
        ],
      });

      // Update the message without tool results (simulating a sync)
      useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "tool",
        content: "Tool result",
        parts: [
          {
            kind: "tool_result",
            toolCallId: "call_123",
            name: "shell_cmd",
            content: "",
            isError: false,
          },
        ],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].toolResults).toHaveLength(1);
      expect(messages[0].toolResults[0].tool_call_id).toBe("call_123");
    });

    it("falls back to streaming segments thinking when broadcast omits thinking (and logs regression)", () => {
      // Regression guard for the tool-call finalization bug:
      // when the server's broadcast assistant message omits
      // `thinking` but the streaming partial had it in
      // `segments`, the store must preserve it. The fallback
      // triggers a `console.error` with the `[NEST REGRESSION]`
      // prefix so the regression is visible in the browser dev
      // tools.
      const consoleErrorSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});
      // The streaming-vs-final check inside `addChatMessage`
      // also fires a `console.warn` (a false positive here —
      // the partial has thinking but no text, so the diff is
      // expected). Silence it so the test output stays focused
      // on the regression guard's own error log.
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      // Seed a streaming partial with thinking in `parts`
      // (the shape produced by `addChatDelta` for thinking
      // deltas).
      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            streaming: {
              messageIndex: 1,
              parts: [
                { kind: "thinking", thinking: "Let me check the directory. " },
                { kind: "thinking", thinking: "I'll run ls." },
              ],
            },
          },
        },
      }));

      // Broadcast the tool-call assistant message with NO
      // thinking field (the regression shape). The new wire
      // format uses `parts` (text + tool_use, no thinking) so
      // the store must fall back to the streaming partial's
      // thinking segments.
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        parts: [
          { kind: "text", text: "Running ls" },
          { kind: "tool_use", id: "call_1", name: "shell_cmd", arguments: {} },
        ],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].thinking).toBe(
        "Let me check the directory. I'll run ls.",
      );
      expect(messages[0].toolCalls).toHaveLength(1);

      // The fallback must have triggered the regression warning.
      expect(consoleErrorSpy).toHaveBeenCalled();
      const firstCallArgs = consoleErrorSpy.mock.calls[0];
      expect(firstCallArgs[0]).toContain("[NEST REGRESSION]");
      expect(firstCallArgs[0]).toContain(
        "Broadcast thinking shorter than streaming partial",
      );

      // Streaming is cleared.
      expect(useStore.getState().agentsCache["agent-1"].streaming).toBeNull();

      consoleErrorSpy.mockRestore();
      warnSpy.mockRestore();
    });

    it("prefers the streaming partial when broadcast thinking is strictly shorter (non-empty)", () => {
      // Defensive: if the broadcast message has thinking but
      // it's strictly shorter than what streamed in (a BEAM-
      // side abbreviation path we couldn't reproduce, but may
      // exist), the JS should prefer the longer streaming
      // value and log a `[NEST REGRESSION]` so the divergence
      // is visible.
      const consoleErrorSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            streaming: {
              messageIndex: 1,
              parts: [
                {
                  kind: "thinking",
                  thinking: "Full reasoning that streamed in chunk by chunk.",
                },
              ],
            },
          },
        },
      }));

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        parts: [
          { kind: "text", text: "OK" },
          {
            kind: "thinking",
            thinking: "Short",
          },
          { kind: "tool_use", id: "call_1", name: "shell_cmd", arguments: {} },
        ],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      // The streaming value is preserved (longer than the
      // broadcast).
      expect(messages[0].thinking).toBe(
        "Full reasoning that streamed in chunk by chunk.",
      );

      expect(consoleErrorSpy).toHaveBeenCalled();
      const firstCallArgs = consoleErrorSpy.mock.calls[0];
      expect(firstCallArgs[0]).toContain("[NEST REGRESSION]");
      expect(firstCallArgs[0]).toContain(
        "Broadcast thinking shorter than streaming partial",
      );

      consoleErrorSpy.mockRestore();
      warnSpy.mockRestore();
    });

    it("trusts the broadcast when it's the same length as the streaming partial", () => {
      // Equal-length but byte-for-byte equal: the broadcast is
      // authoritative (no regression to log).
      const consoleErrorSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});

      const thinking = "Same content streamed in.";

      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            streaming: {
              messageIndex: 1,
              parts: [{ kind: "thinking", thinking }],
            },
          },
        },
      }));

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        parts: [{ kind: "thinking", thinking }],
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].thinking).toBe(thinking);

      // No regression log when lengths match (the broadcast
      // could be a faithful re-emission of the streaming
      // value).
      const regressionLogs = consoleErrorSpy.mock.calls.filter((call) =>
        call[0]?.includes?.("[NEST REGRESSION]"),
      );
      expect(regressionLogs).toHaveLength(0);

      consoleErrorSpy.mockRestore();
    });

    it("does NOT override broadcast thinking with partial segments thinking", () => {
      // The inverse: when the broadcast message has thinking,
      // the partial's segments are NOT used. The broadcast is
      // the source of truth.
      const consoleErrorSpy = vi
        .spyOn(console, "error")
        .mockImplementation(() => {});
      // Silence the streaming-vs-final false-positive warning
      // (the partial has no text, the broadcast has text).
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            streaming: {
              messageIndex: 1,
              content: "",
              segments: [
                { type: "thinking", content: "Stale partial thinking" },
              ],
            },
          },
        },
      }));

      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        content: "Hello",
        thinking: "Authoritative broadcast thinking",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages[0].thinking).toBe("Authoritative broadcast thinking");
      expect(consoleErrorSpy).not.toHaveBeenCalled();

      consoleErrorSpy.mockRestore();
      warnSpy.mockRestore();
    });
  });

  describe("addChatMessage index-mismatch reconcile (regression: optimistic/server race)", () => {
    // The user reports seeing their own message twice in the
    // chat UI. Root cause: the client optimistic-adds at
    // `lastIndex + 1` (a stale value when the user sends a
    // message in the small window between the `init` event and
    // the `chat:sync` response). The server stamps the user
    // message at its authoritative `next_message_index` and
    // broadcasts `chat:message` with that index. The
    // index-based de-dup misses, so the server's echo is
    // appended as a new message.
    //
    // Fix: when the index-based match fails, fall back to a
    // content+role+recency match against an optimistic message.
    // The matched message's index is updated in place to the
    // server's authoritative value.

    // The streaming-vs-final check inside `addChatMessage` fires
    // a `console.warn` when the (empty) assistant partial text
    // doesn't match the incoming user message text. In production
    // those indices never coincide (the user message and the
    // assistant's expected slot differ), but these tests use a
    // fresh cache with `lastIndex = -1` so the optimistic user
    // lands at index 0 and the streaming assistant slot is
    // computed as 0 + 1 = 1 — which collides with the server's
    // authoritative index 1 for the user message. Silence the
    // false positive so the test output stays clean.
    let warnSpy;
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      // messageCount: 1 simulates the server having a system
      // message at index 0 that the client hasn't synced yet.
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 1,
      });
      warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    });
    afterEach(() => {
      warnSpy.mockRestore();
    });

    it("reconciles the optimistic user message when the server echo has a different index", () => {
      // Optimistic add uses `lastIndex + 1`. lastIndex is -1
      // here (the chat:sync response hasn't arrived), so the
      // optimistic message lands at index 0.
      useStore.getState().addUserMessage("agent-1", "Hello");
      expect(useStore.getState().agentsCache["agent-1"].messages).toHaveLength(
        1,
      );
      expect(useStore.getState().agentsCache["agent-1"].messages[0].index).toBe(
        0,
      );

      // Server echoes with the authoritative index 1 (the
      // system message is at index 0 server-side).
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "user",
        parts: [{ kind: "text", text: "Hello" }],
        mode: "chat",
      });

      // The optimistic message is reconciled: the index is
      // updated to the server's value, no duplicate is added.
      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(1);
      expect(messages[0].index).toBe(1);
      expect(messages[0].role).toBe("user");
      expect(messages[0].content).toBe("Hello");
      // lastIndex follows the server's authoritative index.
      expect(useStore.getState().agentsCache["agent-1"].lastIndex).toBe(1);
    });

    it("does not reconcile with a message whose content differs", () => {
      useStore.getState().addUserMessage("agent-1", "Hello");
      expect(useStore.getState().agentsCache["agent-1"].messages).toHaveLength(
        1,
      );

      // Server echoes a different message (e.g. a previously
      // broadcast message that the client had lost). Content
      // doesn't match the optimistic "Hello", so this is a
      // brand-new message and must be appended.
      useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "user",
        parts: [{ kind: "text", text: "Completely different" }],
        mode: "chat",
      });

      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(2);
      expect(messages[0].content).toBe("Hello");
      expect(messages[0].index).toBe(0);
      expect(messages[1].content).toBe("Completely different");
      expect(messages[1].index).toBe(1);
    });

    it("does not reconcile with a message older than the recency threshold", () => {
      // Seed an "old" message with a timestamp 60 seconds in
      // the past. A real user can't have an optimistic message
      // older than 30 seconds in normal use, so the reconcile
      // path must not match this.
      const oldTimestamp = new Date(Date.now() - 60_000).toISOString();
      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            messages: [
              {
                index: 0,
                role: "user",
                parts: [{ kind: "text", text: "Hello" }],
                content: "Hello",
                timestamp: oldTimestamp,
              },
            ],
            lastIndex: 0,
          },
        },
      }));

      useStore.getState().addChatMessage("agent-1", {
        index: 5,
        role: "user",
        parts: [{ kind: "text", text: "Hello" }],
        mode: "chat",
      });

      // The old message is too old to reconcile, so a new
      // message is appended at index 5 instead.
      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(2);
      expect(messages[0].content).toBe("Hello");
      expect(messages[0].index).toBe(0);
      expect(messages[1].content).toBe("Hello");
      expect(messages[1].index).toBe(5);
    });

    it("does not reconcile with a message whose timestamp is missing or malformed", () => {
      // Messages with no `timestamp` (e.g. legacy fixtures) or
      // with a malformed `timestamp` (e.g. from a buggy
      // client) must not be reconciled — the recency check
      // can't compute a delta, so it conservatively skips
      // matching.
      useStore.setState((state) => ({
        agentsCache: {
          ...state.agentsCache,
          "agent-1": {
            ...state.agentsCache["agent-1"],
            messages: [
              {
                index: 0,
                role: "user",
                parts: [{ kind: "text", text: "Hello" }],
                content: "Hello",
                // No timestamp field.
              },
            ],
            lastIndex: 0,
          },
        },
      }));

      useStore.getState().addChatMessage("agent-1", {
        index: 3,
        role: "user",
        parts: [{ kind: "text", text: "Hello" }],
        mode: "chat",
      });

      // The mismatched-timestamp message is not reconciled.
      const messages = useStore.getState().agentsCache["agent-1"].messages;
      expect(messages).toHaveLength(2);
      expect(messages[0].index).toBe(0);
      expect(messages[1].index).toBe(3);
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

  describe("clearAgentCache", () => {
    it("deletes only the agent cache while keeping agents list", () => {
      // Setup
      useStore.getState().addAgent({ name: "agent-1", model: "gpt-4" });
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
        charsReceived: 0,
      });
      expect(cache.partial.parts).toEqual([]);
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
      expect(cache.streaming.parts).toHaveLength(2);
      expect(cache.streaming.parts[0]).toMatchObject({
        kind: "text",
        text: "Hello ",
      });
      expect(cache.streaming.parts[1]).toMatchObject({
        kind: "tool_arguments",
        text: '{"key": "val"}',
      });
    });
  });

  describe("addChatDelta thinking-vs-text split (new protocol)", () => {
    // The store separates thinking deltas from the `content`
    // buffer (the text that `<MessageContent>` renders). Without
    // this split, thinking text appears twice in the chat —
    // once in the yellow box and again as regular markdown
    // below it — and then vanishes on finalization when the
    // assistant message's `content` is rebuilt as text-only.
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("thinking deltas update segments but not content", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 5,
        deltaIndex: 0,
        content: "Reasoning about the answer...",
        partType: "thinking",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      // The thinking text is captured in `parts` (so
      // `thinkingFor(message)` can find it for the yellow box).
      expect(cache.streaming.parts).toHaveLength(1);
      expect(cache.streaming.parts[0]).toMatchObject({
        kind: "thinking",
        thinking: "Reasoning about the answer...",
      });
      // But it is NOT in `content` (so it doesn't appear in the
      // visible reply).
      expect(
        cache.streaming.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("");
    });

    it("text deltas after thinking deltas do not include the thinking text", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 5,
        deltaIndex: 0,
        content: "First thought ",
        partType: "thinking",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 5,
        deltaIndex: 1,
        content: "second thought",
        partType: "thinking",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 5,
        deltaIndex: 2,
        content: "Visible answer",
        partType: "text",
      });

      const cache = useStore.getState().agentsCache["agent-1"];

      // The text content is the text-only buffer — no
      // concatenated thinking text.
      expect(
        cache.streaming.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Visible answer");

      // Both thinking deltas are merged into one part (so
      // the yellow box shows them concatenated) — `accumulatePart`
      // continues the existing part if the kind matches.
      // The text delta starts a new part.
      expect(cache.streaming.parts).toHaveLength(2);
      expect(cache.streaming.parts[0]).toMatchObject({
        kind: "thinking",
        thinking: "First thought second thought",
      });
      expect(cache.streaming.parts[1]).toMatchObject({
        kind: "text",
        text: "Visible answer",
      });
    });
  });

  describe("addChatDelta thinking-vs-text split (legacy partial protocol)", () => {
    // The same split is applied to the legacy
    // `charsStart`/`charsEnd` partial path. Thinking deltas
    // update `segments` only; text deltas accumulate into
    // `content` as before.
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
    });

    it("thinking deltas update segments but not text content", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        charsStart: 0,
        charsEnd: 27,
        content: "Reasoning about the answer...",
        partType: "thinking",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.partial.parts).toHaveLength(1);
      expect(cache.partial.parts[0]).toMatchObject({
        kind: "thinking",
        thinking: "Reasoning about the answer...",
      });
      expect(
        cache.partial.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("");
    });

    it("text deltas accumulate into text parts but not thinking", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        charsStart: 0,
        charsEnd: 14,
        content: "Some reasoning",
        partType: "thinking",
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 5,
        charsStart: 14,
        charsEnd: 28,
        content: "Visible answer",
        partType: "text",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      // Text-only buffer — no thinking text mixed in.
      expect(
        cache.partial.parts
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join(""),
      ).toBe("Visible answer");
      // The thinking text is in the segments list, then the
      // text delta starts a new segment.
      expect(cache.partial.parts).toHaveLength(2);
      expect(cache.partial.parts[0]).toMatchObject({
        kind: "thinking",
        thinking: "Some reasoning",
      });
      expect(cache.partial.parts[1]).toMatchObject({
        kind: "text",
        text: "Visible answer",
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
      useStore.getState().setAgents([{ name: "agent-1", model: "gpt-4" }]);
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

      // Silence the streaming-vs-final false-positive warning
      // (the optimistic user message sets up a streaming slot
      // at index 1 for the assistant; the first broadcast at
      // index 1 happens to collide with that slot, but the
      // test is about the 4-message flow, not the partial
      // diff).
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

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

      warnSpy.mockRestore();
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

    it("filters cache.messages to drop messages with index <= marker.index (post-compaction boundary)", () => {
      // Before the fix, cache.messages kept the pre-swap list
      // after a compaction, so the same messages appeared in
      // both the history pane and the active area. The fix
      // filters cache.messages down to the post-swap list
      // (everything strictly greater than marker.index).
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 6,
        history: [],
        messages: [
          { index: 0, role: "system", content: "system" },
          { index: 1, role: "user", content: "A" },
          { index: 2, role: "assistant", content: "B" },
          { index: 3, role: "user", content: "C" },
          { index: 4, role: "assistant", content: "D" },
          { index: 5, role: "user", content: "E" },
        ],
      });

      // Compaction: marker at index 6, archives indices 0-6
      // (system + 5 user/assistant turns). After the swap,
      // the active list starts at 7.
      useStore.getState().setAgentHistory(
        "agent-1",
        [
          { index: 0, role: "system", content: "system" },
          { index: 1, role: "user", content: "A" },
          { index: 2, role: "assistant", content: "B" },
          { index: 3, role: "user", content: "C" },
          { index: 4, role: "assistant", content: "D" },
          { index: 5, role: "user", content: "E" },
          { index: 6, role: "compaction", archivedCount: 6 },
        ],
        { index: 6, role: "compaction", archivedCount: 6 },
      );

      const cache = useStore.getState().agentsCache["agent-1"];

      // All pre-swap messages (indices 0-6) are gone from
      // cache.messages — they live in cache.history now.
      expect(cache.messages).toEqual([]);
      // The history has all 7 archived rows in order.
      expect(cache.history).toHaveLength(7);
    });

    it("preserves cache.messages with index > marker.index (post-swap segment)", () => {
      // The boundary is `index <= marker.index` — the
      // post-swap active list (indices > marker.index) is
      // preserved, since the sync that follows the compaction
      // is what fills those slots with the new active list.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 10,
        messages: [
          { index: 0, role: "system", content: "system" },
          { index: 1, role: "user", content: "A" },
          { index: 5, role: "user", content: "B" },
          { index: 7, role: "user", content: "C" },
          { index: 8, role: "user", content: "D" },
        ],
      });

      // Marker at index 6 archives indices 0-6. The active
      // list should keep indices 7 and 8.
      useStore.getState().setAgentHistory(
        "agent-1",
        [
          { index: 0, role: "system", content: "system" },
          { index: 1, role: "user", content: "A" },
          { index: 5, role: "user", content: "B" },
          { index: 6, role: "compaction", archivedCount: 3 },
        ],
        { index: 6, role: "compaction", archivedCount: 3 },
      );

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(2);
      expect(cache.messages[0].index).toBe(7);
      expect(cache.messages[1].index).toBe(8);
    });

    it("does not filter cache.messages when the marker has no index", () => {
      // Defensive: if the marker is malformed (no `index`),
      // don't drop the active list — the channel will still
      // try to sync and the user gets a sensible UI.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 1,
        messages: [{ index: 0, role: "user", content: "kept" }],
      });

      useStore.getState().setAgentHistory(
        "agent-1",
        [{ index: 0, role: "user", content: "old" }],
        // marker without an `index` field
        { role: "compaction", archivedCount: 1 },
      );

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toHaveLength(1);
      expect(cache.messages[0].index).toBe(0);
    });
  });

  describe("addChatMessage gap detection (returns {applied, needsSync, snapshotLastIndex})", () => {
    it("returns {applied: false, needsSync: false} for an unknown agent", () => {
      const result = useStore.getState().addChatMessage("non-existent", {
        index: 5,
        role: "user",
        content: "test",
      });
      expect(result).toEqual({ applied: false, needsSync: false });
    });

    it("returns {applied: true, needsSync: false} on the first message (lastIndex === -1)", () => {
      // The `lastIndex >= 0` guard: on the very first message
      // the gap from -1 is expected (the client just joined),
      // not a real loss. No sync is needed.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      const result = useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        parts: [{ kind: "text", text: "Hello" }],
      });

      expect(result).toMatchObject({ applied: true, needsSync: false });
    });

    it("returns {applied: true, needsSync: false} when the message is the expected next index", () => {
      // lastIndex=2, incoming message.index=3 → the expected
      // next index, no gap.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 3,
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
          { index: 2, role: "user", content: "C" },
        ],
      });

      const result = useStore.getState().addChatMessage("agent-1", {
        index: 3,
        role: "assistant",
        parts: [{ kind: "text", text: "D" }],
      });

      expect(result).toMatchObject({ applied: true, needsSync: false });
    });

    it("returns {applied: true, needsSync: true, snapshotLastIndex: 2} when the message is a genuine gap", () => {
      // lastIndex=2, incoming message.index=5 → gap of 2
      // (messages 3 and 4 are missing). The channel handler
      // reads `needsSync: true` and `snapshotLastIndex: 2`
      // and calls `requestSync` to fill the gap from index 2
      // (not from index 5, which would skip the missing
      // messages).
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 3,
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
          { index: 2, role: "user", content: "C" },
        ],
      });

      const result = useStore.getState().addChatMessage("agent-1", {
        index: 5,
        role: "assistant",
        parts: [{ kind: "text", text: "E" }],
      });

      expect(result).toEqual({
        applied: true,
        needsSync: true,
        snapshotLastIndex: 2,
      });
    });

    it("returns {applied: true, needsSync: false} when the message matches an existing index (re-broadcast)", () => {
      // The server can re-broadcast a message that the
      // client already has (e.g. via api_log updates). The
      // matchedIndex path merges; no gap.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 3,
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
          { index: 2, role: "user", content: "C" },
        ],
      });

      const result = useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        parts: [{ kind: "text", text: "B (re-broadcast)" }],
      });

      expect(result).toMatchObject({ applied: true, needsSync: false });
    });

    it("returns {applied: true, needsSync: false} when the message reconciles an optimistic add", () => {
      // The optimistic-reconcile path matches by content +
      // recency when the index differs. matchedIndex !== -1
      // even though the indices diverge, so no gap signal.
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        useStore.getState().setAgentConnecting("agent-1");
        useStore.getState().setAgentConnected("agent-1", {
          model: { name: "gpt-4" },
          messageCount: 1,
        });
        // Optimistic add uses `lastIndex + 1` = 0
        useStore.getState().addUserMessage("agent-1", "Hello");

        // Server echoes with the authoritative index 1
        const result = useStore.getState().addChatMessage("agent-1", {
          index: 1,
          role: "user",
          parts: [{ kind: "text", text: "Hello" }],
          mode: "chat",
        });

        expect(result).toMatchObject({ applied: true, needsSync: false });
      } finally {
        warnSpy.mockRestore();
      }
    });

    it("returns snapshotLastIndex: -1 on the first message (so the channel handler can fall back to cache.lastIndex)", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      const result = useStore.getState().addChatMessage("agent-1", {
        index: 0,
        role: "user",
        parts: [{ kind: "text", text: "Hello" }],
      });

      expect(result).toMatchObject({ snapshotLastIndex: -1 });
    });

    it("handles thinking parts with empty/missing `thinking` text (the `p.thinking || ''` fallback)", () => {
      // A `Part.Thinking` may have a `thinking` field that's
      // null or empty (rare, but possible). The `fromParts`
      // helper concatenates with `p.thinking || ""` so the
      // resulting string is empty rather than "null".
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 1,
        messages: [{ index: 0, role: "user", content: "Q" }],
      });

      // The message has a thinking part with no text. The
      // function should not throw; thinking should be null
      // (empty string converted to null).
      const result = useStore.getState().addChatMessage("agent-1", {
        index: 1,
        role: "assistant",
        parts: [
          { kind: "thinking", thinking: null },
          { kind: "text", text: "A" },
        ],
      });

      expect(result).toMatchObject({ applied: true });
      const cache = useStore.getState().agentsCache["agent-1"];
      const added = cache.messages.find((m) => m.index === 1);
      expect(added.thinking).toBe(null);
    });

    it("handles refusal deltas via the streaming accumulator (covers the refusal branch in appendPart)", () => {
      // The streaming accumulator's `appendPart` has a
      // refusal branch (line 157) hit when a refusal delta
      // extends a refusal part. The default `newPart` branch
      // (line 149, returning `{kind:"text", text}`) is hit
      // when the part kind is unknown.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      // Stream a refusal delta
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 0,
        deltaIndex: 0,
        content: "I cannot",
        partType: "refusal",
      });

      // Extend it with another refusal delta
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 0,
        deltaIndex: 1,
        content: " do that",
        partType: "refusal",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const refusalPart = cache.streaming.parts.find(
        (p) => p.kind === "refusal",
      );
      expect(refusalPart.refusal).toBe("I cannot do that");
    });
  });

  describe("addChatDelta with unknown part kind (default newPart branch)", () => {
    it("falls back to a text part when the part kind is unknown", () => {
      // The streaming accumulator's `newPart` has a default
      // branch (line 149) hit when `kind` is anything other
      // than the known kinds. The default returns
      // `{kind: "text", text: content}` so the unknown kind
      // is rendered as text. This is a defensive fallback
      // for forward-compatibility with new part kinds the
      // LLM might emit before the UI is updated.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 0,
        deltaIndex: 0,
        content: "future kind",
        partType: "future_kind",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      // Unknown kind falls back to a text part.
      const textPart = cache.streaming.parts.find((p) => p.kind === "text");
      expect(textPart.text).toBe("future kind");
    });

    it("creates a tool_use part when the streaming delta's partType is 'tool_use'", () => {
      // The `newPart` factory has a tool_use branch (line
      // 123) that returns the part shape with `id`, `name`,
      // and `arguments` keys (instead of the text default).
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 0,
        deltaIndex: 0,
        content: "shell_cmd",
        partType: "tool_use",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const toolUsePart = cache.streaming.parts.find(
        (p) => p.kind === "tool_use",
      );
      // The streaming accumulator seeds the tool_use part
      // with `name: null` (the actual name arrives via a
      // later streaming event with `toolCallName`); the
      // `text` field carries the streaming content.
      expect(toolUsePart).toBeDefined();
      expect(toolUsePart.kind).toBe("tool_use");
    });

    it("creates a tool_result part when the streaming delta's partType is 'tool_result'", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 0,
        deltaIndex: 0,
        content: "file1.txt\nfile2.txt",
        partType: "tool_result",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const toolResultPart = cache.streaming.parts.find(
        (p) => p.kind === "tool_result",
      );
      expect(toolResultPart.content).toBe("file1.txt\nfile2.txt");
    });
  });

  describe("addChatDelta tool_use_start / tool_use_delta (live tool-call streaming)", () => {
    // The BEAM broadcasts tool-use events as `chat:delta` with
    // `partType: "tool_use_start"` (carrying the call's `id`
    // and `name`) and `partType: "tool_use_delta"` (carrying
    // an `arguments_delta` fragment). The store maps these to
    // a single `tool_use` part with id+name+arguments so the
    // streaming partial can render the in-flight tool call.
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });
    });

    it("creates a tool_use part with id+name from tool_use_start", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 0,
        content: "",
        partType: "tool_use_start",
        toolCallId: "call_abc",
        toolCallName: "shell_cmd",
        toolCallBlockIndex: 0,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const toolUsePart = cache.streaming.parts.find(
        (p) => p.kind === "tool_use",
      );
      expect(toolUsePart).toBeDefined();
      expect(toolUsePart.id).toBe("call_abc");
      expect(toolUsePart.name).toBe("shell_cmd");
      // Arguments start empty — appended by subsequent deltas.
      expect(toolUsePart.arguments).toBe("");
      expect(cache.streaming.currentKind).toBe("tool_use");
    });

    it("appends arguments_delta fragments to the matching tool_use part", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 0,
        partType: "tool_use_start",
        toolCallId: "call_abc",
        toolCallName: "shell_cmd",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 1,
        content: '{"command":',
        partType: "tool_use_delta",
        toolCallId: "call_abc",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 2,
        content: ' "ls"}',
        partType: "tool_use_delta",
        toolCallId: "call_abc",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const toolUsePart = cache.streaming.parts.find(
        (p) => p.kind === "tool_use",
      );
      expect(toolUsePart.arguments).toBe('{"command": "ls"}');
    });

    it("treats a duplicate tool_use_start as a no-op (preserves existing arguments)", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 0,
        partType: "tool_use_start",
        toolCallId: "call_abc",
        toolCallName: "shell_cmd",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 1,
        content: '{"command":"ls"}',
        partType: "tool_use_delta",
        toolCallId: "call_abc",
      });
      // A retransmitted start (same id) must NOT clobber the
      // accumulated arguments.
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 2,
        partType: "tool_use_start",
        toolCallId: "call_abc",
        toolCallName: "shell_cmd",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const toolUseParts = cache.streaming.parts.filter(
        (p) => p.kind === "tool_use" && p.id === "call_abc",
      );
      expect(toolUseParts).toHaveLength(1);
      expect(toolUseParts[0].arguments).toBe('{"command":"ls"}');
    });

    it("drops a tool_use_delta that arrives before any matching start (no part to append to)", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 0,
        content: '{"command":"ls"}',
        partType: "tool_use_delta",
        toolCallId: "call_orphan",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      // No tool_use part was created; the delta was a no-op.
      expect(
        cache.streaming.parts.find((p) => p.kind === "tool_use"),
      ).toBeUndefined();
    });

    it("preserves thinking parts that streamed in before a tool_use_start arrived", () => {
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 0,
        content: "Let me check the directory. ",
        partType: "thinking",
      });
      useStore.getState().addChatDelta("agent-1", {
        messageIndex: 1,
        deltaIndex: 1,
        partType: "tool_use_start",
        toolCallId: "call_abc",
        toolCallName: "shell_cmd",
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      const thinkingPart = cache.streaming.parts.find(
        (p) => p.kind === "thinking",
      );
      const toolUsePart = cache.streaming.parts.find(
        (p) => p.kind === "tool_use",
      );
      expect(thinkingPart.thinking).toBe("Let me check the directory. ");
      expect(toolUsePart.id).toBe("call_abc");
    });
  });

  describe("syncAgentMessages with the new streaming wire format", () => {
    it("normalizes payload.streaming (the new format) into the canonical cache shape", () => {
      // The new wire format uses `payload.streaming`
      // (with `lastDeltaIndex`) instead of the legacy
      // `payload.partial` (with `charsEnd`). The
      // `syncAgentMessages` action normalizes the new
      // shape into the cache's `streaming` field with
      // `nextDeltaIndex: lastDeltaIndex + 1`.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        streaming: {
          lastDeltaIndex: 3,
          messageIndex: 1,
          role: "assistant",
          parts: [{ kind: "text", text: "Streaming..." }],
        },
        messageCount: 1,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.streaming).toMatchObject({
        messageIndex: 1,
        nextDeltaIndex: 4,
        role: "assistant",
      });
    });
  });

  describe("legacy addChatDelta with tool_use_start / tool_use_delta", () => {
    // Regression for the wire-up gap that left tool-call
    // streaming in the dark. The legacy wire format uses
    // `charsStart` / `charsEnd` (not `deltaIndex`) and the
    // payload carries `partType: "tool_use_start"` /
    // `"tool_use_delta"`. Tool-use events ship `chars_end: 0`
    // (the fragment is the partial-JSON content, not a
    // grapheme position), so we have to make sure the store
    // doesn't clobber the running `charsReceived` when it
    // applies them — otherwise the next text delta trips the
    // integrity check and triggers a wasteful `chat:sync`.
    beforeEach(() => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [],
      });
    });

    it("tool_use_start preserves the running charsReceived", () => {
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Let me check",
        charsReceived: 12,
        parts: [{ kind: "text", text: "Let me check" }],
        currentKind: "text",
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_start",
        toolCallId: "call_legacy",
        toolCallName: "shell_cmd",
        charsStart: 0,
        charsEnd: 0,
        content: "",
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      // The bug: `charsReceived` was unconditionally reset to
      // `charsEnd` (= 0), which would force the next text
      // delta to look like a gap.
      expect(partial.charsReceived).toBe(12);
      const toolPart = partial.parts.find((p) => p.kind === "tool_use");
      expect(toolPart.id).toBe("call_legacy");
      expect(toolPart.name).toBe("shell_cmd");
      expect(partial.currentKind).toBe("tool_use");
    });

    it("tool_use_delta appends to the matching tool_use part without touching charsReceived", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_start",
        toolCallId: "call_legacy",
        toolCallName: "shell_cmd",
        charsStart: 0,
        charsEnd: 0,
        content: "",
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_delta",
        toolCallId: "call_legacy",
        charsStart: 0,
        charsEnd: 0,
        content: '{"command":',
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_delta",
        toolCallId: "call_legacy",
        charsStart: 0,
        charsEnd: 0,
        content: '"ls"}',
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      const toolPart = partial.parts.find((p) => p.kind === "tool_use");
      expect(toolPart.arguments).toBe('{"command":"ls"}');
      expect(partial.charsReceived).toBe(0);
    });

    it("text delta after a tool_use_delta does not trigger needsSync", () => {
      // The bug: `charsReceived` was clobbered to 0 by the
      // tool_use event, so the next text delta (with
      // charsStart=N > charsReceived=0) tripped `needsSync`.
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "before ",
        charsReceived: 7,
        parts: [{ kind: "text", text: "before " }],
        currentKind: "text",
      };

      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_start",
        toolCallId: "call_post",
        toolCallName: "noop",
        charsStart: 0,
        charsEnd: 0,
        content: "",
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_delta",
        toolCallId: "call_post",
        charsStart: 0,
        charsEnd: 0,
        content: "{}",
      });

      const beforeText = useStore.getState().agentsCache["agent-1"].partial;
      expect(beforeText.charsReceived).toBe(7);

      // Now apply a text delta that picks up where the
      // original text left off.
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        content: "after",
        charsStart: 7,
        charsEnd: 11,
      });

      const afterText = useStore.getState().agentsCache["agent-1"].partial;
      expect(afterText.charsReceived).toBe(11);
    });

    it("multi-call interleaving: a second tool_use_start creates a second tool_use part", () => {
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_start",
        toolCallId: "call_a",
        toolCallName: "first",
        charsStart: 0,
        charsEnd: 0,
        content: "",
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_start",
        toolCallId: "call_b",
        toolCallName: "second",
        charsStart: 0,
        charsEnd: 0,
        content: "",
      });
      useStore.getState().addChatDelta("agent-1", {
        index: 1,
        partType: "tool_use_delta",
        toolCallId: "call_b",
        charsStart: 0,
        charsEnd: 0,
        content: '{"k":1}',
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      const parts = partial.parts.filter((p) => p.kind === "tool_use");
      expect(parts).toHaveLength(2);
      expect(parts[0].id).toBe("call_a");
      expect(parts[0].arguments).toBe("");
      expect(parts[1].id).toBe("call_b");
      expect(parts[1].arguments).toBe('{"k":1}');
    });
  });

  describe("setAgentConnected normalizes in-flight tool calls from init partial", () => {
    // Regression for the "mid-stream join" gap: the BEAM's
    // `Streaming.to_json/1` carries a `toolCalls` array with
    // partial-JSON strings for any in-flight tool calls. The
    // JS `setAgentConnected` (via `normalizePartial`) must
    // convert those into `tool_use` parts so the joining
    // client renders them in real time, not just text.
    it("synthesizes a tool_use part for each in-flight tool call", () => {
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        partial: {
          index: 2,
          role: "assistant",
          content: "Let me check",
          charsEnd: 12,
          segments: [
            { type: "text", content: "Let me check" },
            { type: "tool_use", id: "call_x" },
          ],
          toolCalls: [
            {
              id: "call_x",
              name: "shell_cmd",
              arguments: '{"command":',
            },
          ],
          currentType: ["tool_use", "call_x"],
        },
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.parts).toEqual([
        { kind: "text", text: "Let me check" },
        {
          kind: "tool_use",
          id: "call_x",
          name: "shell_cmd",
          arguments: '{"command":',
        },
      ]);
      expect(partial.currentKind).toBe("tool_use");
    });

    it("appends toolCalls entries that are not referenced by segments", () => {
      // Defensive: if the BEAM ever ships toolCalls without a
      // matching tool_use marker in segments, we still want
      // them rendered.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        partial: {
          index: 2,
          content: "x",
          charsEnd: 1,
          segments: [{ type: "text", content: "x" }],
          toolCalls: [{ id: "orphan", name: "noop", arguments: "" }],
          currentType: "text",
        },
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      const toolPart = partial.parts.find((p) => p.kind === "tool_use");
      expect(toolPart).toMatchObject({
        id: "orphan",
        name: "noop",
        arguments: "",
      });
    });

    it("collapses a currentType tuple to its kind string", () => {
      // The wire sends `currentType: {:tool_use, id}` which
      // JSON-encodes to `["tool_use", "call_abc"]`. The store
      // must surface just the kind ("tool_use"), not the
      // array.
      useStore.getState().setAgentConnecting("agent-1");
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        partial: {
          index: 2,
          content: "",
          charsEnd: 0,
          segments: [],
          toolCalls: [{ id: "call_abc", name: "noop", arguments: "" }],
          currentType: ["tool_use", "call_abc"],
        },
      });

      const partial = useStore.getState().agentsCache["agent-1"].partial;
      expect(partial.currentKind).toBe("tool_use");
    });
  });

  describe("setCurrentUser", () => {
    it("sets the current user", () => {
      expect(useStore.getState().currentUser).toBe(null);

      useStore.getState().setCurrentUser({ id: 1, username: "alice" });

      expect(useStore.getState().currentUser).toEqual({
        id: 1,
        username: "alice",
      });
    });
  });

  describe("setInvites", () => {
    it("replaces the invites list with the provided array", () => {
      expect(useStore.getState().invites).toEqual([]);

      useStore.getState().setInvites([
        { id: 1, token: "abc" },
        { id: 2, token: "def" },
      ]);

      expect(useStore.getState().invites).toEqual([
        { id: 1, token: "abc" },
        { id: 2, token: "def" },
      ]);
    });

    it("treats undefined as an empty list", () => {
      useStore.getState().setInvites([{ id: 1, token: "abc" }]);
      expect(useStore.getState().invites).toHaveLength(1);

      useStore.getState().setInvites(undefined);

      expect(useStore.getState().invites).toEqual([]);
    });
  });

  describe("setInvitesError", () => {
    it("sets the invitesError string", () => {
      expect(useStore.getState().invitesError).toBe(null);

      useStore.getState().setInvitesError("too_many_invites");

      expect(useStore.getState().invitesError).toBe("too_many_invites");
    });

    it("clears the invitesError when set to null", () => {
      useStore.getState().setInvitesError("boom");
      expect(useStore.getState().invitesError).toBe("boom");

      useStore.getState().setInvitesError(null);

      expect(useStore.getState().invitesError).toBe(null);
    });
  });

  describe("logout", () => {
    it("resets every piece of session state", () => {
      // Seed state across multiple slices.
      useStore.getState().setIsConnected(true);
      useStore.getState().setAgents([{ name: "agent-1" }]);
      useStore.getState().setCurrentUser({ id: 1, username: "alice" });
      useStore.getState().setInvites([{ id: 1, token: "abc" }]);
      useStore.getState().setInvitesError("some error");

      useStore.getState().logout();

      expect(useStore.getState().isConnected).toBe(false);
      expect(useStore.getState().agents).toEqual([]);
      expect(useStore.getState().currentUser).toBe(null);
      expect(useStore.getState().invites).toEqual([]);
      expect(useStore.getState().invitesError).toBe(null);
      expect(useStore.getState().agentsCache).toEqual({});
    });
  });
});
