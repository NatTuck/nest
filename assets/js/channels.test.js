/**
 * Tests for channels.js behavior
 * Verifies protocol compliance with agent-channel-protocol.md
 * All tests verify behavior through store state changes only
 */

import { describe, it, beforeEach, vi } from "vitest";
import assert from "node:assert";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  simulateServerEvent,
  connectSocket,
  disconnectSocket,
  errorSocket,
} from "./__mocks__/phoenix";
import { useStore } from "./store";
import {
  initChannels,
  joinLobby,
  leaveLobby,
  joinAgent,
  leaveAgent,
  sendMessage,
  createAgent,
  deleteAgent,
  clearAgentChannels,
} from "./channels";

describe("channels", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  describe("initChannels", () => {
    it("should update store.isConnected to true when socket connects", async () => {
      initChannels();
      connectSocket();
      // Wait for async callback
      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });
    });

    it("should update store.isConnected to false when socket disconnects", async () => {
      initChannels();
      connectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });

      disconnectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, false);
      });
    });

    it("should update store.isConnected to false when socket errors", async () => {
      initChannels();
      connectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });

      errorSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, false);
      });
    });
  });

  describe("joinLobby", () => {
    it("should set store.agents when receiving init event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [{ id: "agent-1", name: "Test Agent" }],
          models: [],
        },
      });

      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      assert.deepStrictEqual(useStore.getState().agents, [
        { id: "agent-1", name: "Test Agent" },
      ]);
    });

    it("should set store.models when receiving init event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [{ name: "gpt-4", provider: "openai" }],
        },
      });

      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().models.length, 1);
      });

      assert.deepStrictEqual(useStore.getState().models, [
        { name: "gpt-4", provider: "openai" },
      ]);
    });

    it("should call onOk callback on successful join", async () => {
      let called = false;
      joinLobby(() => {
        called = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(called, true);
      });
    });

    it("should call onError callback on join error", async () => {
      let errorCalled = false;
      let errorReason = null;
      setNextJoinResult("lobby", { error: "lobby_full" });
      joinLobby(
        () => {},
        (err) => {
          errorCalled = true;
          errorReason = err.reason;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
      assert.strictEqual(errorReason, "lobby_full");
    });

    it("should log console error on lobby join failure", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("lobby", { error: "lobby_full" });

      joinLobby(
        () => {},
        () => {},
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Lobby channel join error"),
      );
      assert.ok(errorMessage, "Expected console error for lobby join failure");

      errorSpy.mockRestore();
    });

    it("should be idempotent - call onOk immediately if already joined", async () => {
      let firstCalled = false;
      let secondCalled = false;

      joinLobby(() => {
        firstCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(firstCalled, true);
      });

      joinLobby(() => {
        secondCalled = true;
      });

      assert.strictEqual(secondCalled, true);
    });
  });

  describe("lobby events", () => {
    it("should add agent to store.agents on agent:created event", async () => {
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 0);
      });

      simulateServerEvent("lobby", "agent:created", {
        id: "new-agent",
        model: { name: "gpt-4", provider: "openai" },
      });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });
      assert.strictEqual(useStore.getState().agents[0].id, "new-agent");
    });

    it("should remove agent from store.agents on agent:deleted event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [{ id: "agent-1", model: { name: "gpt-4" } }],
          models: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      simulateServerEvent("lobby", "agent:deleted", { id: "agent-1" });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 0);
      });
    });

    it("should clear agent cache when agent is deleted", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [{ id: "agent-1", model: { name: "gpt-4" } }],
          models: [],
        },
      });
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      simulateServerEvent("lobby", "agent:deleted", { id: "agent-1" });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 0);
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"],
          undefined,
        );
      });
    });
  });

  describe("leaveLobby", () => {
    it("should leave the lobby channel", async () => {
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      leaveLobby();

      let errorCalled = false;
      createAgent(
        "gpt-4",
        1,
        null,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("joinAgent", () => {
    it("should set agent status to connecting in store before join completes", () => {
      joinAgent("agent-1");
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.status,
        "connecting",
      );
    });

    it("should store init payload - status, model, but not set lastIndex from messageCount", async () => {
      setNextJoinResult("agent:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "claude-3", provider: "anthropic" },
          messageCount: 5,
          status: "idle",
        },
      });

      joinAgent("agent-1");

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.status, "connected");
        assert.strictEqual(cache?.model?.name, "claude-3");
        // lastIndex is not set from messageCount, only from actual messages
        assert.strictEqual(cache?.lastIndex, -1);
      });
    });

    it("should trigger sync when server messageCount > cached lastIndex", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [{ index: 0, role: "user", content: "Hello" }],
      });

      setNextJoinResult("agent:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 3,
          status: "idle",
          messages: [{ index: 0, role: "user", content: "Hello" }],
        },
      });

      setNextPushResult("agent:agent-1", "chat:sync", {
        ok: {
          messages: [
            { index: 1, role: "assistant", content: "Response 1" },
            { index: 2, role: "user", content: "Question" },
            { index: 3, role: "assistant", content: "Response 2" },
          ],
          messageCount: 3,
        },
      });

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          4,
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.lastIndex,
          3,
        );
      });
    });

    it("should set agent status to error on join error", async () => {
      setNextJoinResult("agent:agent-1", { error: "agent_not_found" });
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "error",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.error,
          "agent_not_found",
        );
      });
    });

    it("should log console error on agent join failure", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("agent:agent-1", { error: "agent_not_found" });

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Agent agent-1 channel join error"),
      );
      assert.ok(errorMessage, "Expected console error for agent join failure");

      errorSpy.mockRestore();
    });

    it("should set agent status to error on join timeout", async () => {
      setNextJoinResult("agent:agent-1", { timeout: true });
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "error",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.error,
          "Connection timed out",
        );
      });
    });

    it("should log console error on agent join timeout", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("agent:agent-1", { timeout: true });

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Agent agent-1 channel join timeout"),
      );
      assert.ok(errorMessage, "Expected console error for agent join timeout");

      errorSpy.mockRestore();
    });

    it("should handle rejoin - send chat:status and update from response", async () => {
      setNextJoinResult("agent:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.model?.name,
          "gpt-4",
        );
      });

      setNextPushResult("agent:agent-1", "chat:status", {
        ok: {
          model: { name: "claude-3", provider: "anthropic" },
          messageCount: 0,
        },
      });

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.model?.name,
          "claude-3",
        );
      });
    });
  });

  describe("agent chat:delta events", () => {
    it("should append delta content to partial message", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "Hello",
        charsStart: 0,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.content,
          "Hello",
        );
      });
    });

    it("should accumulate multiple deltas", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "Hel",
        charsStart: 0,
        charsEnd: 3,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.content,
          "Hel",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "lo",
        charsStart: 3,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.content,
          "Hello",
        );
      });
    });

    it("should reset partial when delta index changes", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Old content",
      };

      joinAgent("agent-1");

      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 3,
        content: "New",
        charsStart: 0,
        charsEnd: 3,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.index,
          3,
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.content,
          "New",
        );
      });
    });

    it("should set waitingForResponse to false on first delta", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      useStore.getState().agentsCache["agent-1"].waitingForResponse = true;

      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "Hello",
        charsStart: 0,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.waitingForResponse,
          false,
        );
      });
    });

    it("should detect gap and return needsSync when charsStart > charsReceived", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 3 chars
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Send delta that starts at 5 (gap from 3-5)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "lo!",
        charsStart: 5,
        charsEnd: 8,
      });

      assert.deepStrictEqual(result, { applied: false, needsSync: true });
      // Content should not have changed
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.partial?.content,
        "Hel",
      );
    });

    it("should handle overlap by slicing correctly", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 3 chars
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Send overlapping delta: charsStart=2, content="llo" (overlap is 1 char "l")
      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "llo",
        charsStart: 2,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        // Should have sliced to just "lo" and appended
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.content,
          "Hello",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.charsReceived,
          5,
        );
      });
    });

    it("should detect overlap mismatch and continue with server data", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 3 chars: "Hel"
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Send overlapping delta with mismatch: charsStart=2, content="xyz" (overlap is 1 char)
      // Expected overlap is "l", actual is "z"
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "xyz",
        charsStart: 2,
        charsEnd: 5,
      });

      // Should have mismatch flag
      assert.strictEqual(result.overlapMismatch, true);
      // But still applied the new content (sliced to "yz")
      assert.strictEqual(result.applied, true);
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.partial?.content,
        "Helyz",
      );
    });

    it("should not apply delta when overlap consumes entire content", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 5 chars: "Hello"
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hello",
        charsReceived: 5,
      };

      // Send delta that's entirely in the past: charsStart=3, content="lo" (overlap=2)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "lo",
        charsStart: 3,
        charsEnd: 5,
      });

      // Should not have applied anything new
      assert.strictEqual(result.applied, false);
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.partial?.content,
        "Hello",
      );
    });
  });

  describe("agent chat:message events", () => {
    it("should add complete message to messages array", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "Hello",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          1,
        );
      });
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.messages[0]?.content,
        "Hello",
      );
    });

    it("should clear partial when message index matches", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 3,
        content: "Streaming",
      };

      joinAgent("agent-1");

      simulateServerEvent("agent:agent-1", "chat:message", {
        index: 3,
        role: "assistant",
        content: "Complete",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial,
          null,
        );
      });
    });

    it("should update lastIndex to message index", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:message", {
        index: 5,
        role: "user",
        content: "Test",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.lastIndex,
          5,
        );
      });
    });

    it("should not duplicate messages with same index", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "First",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          1,
        );
      });

      simulateServerEvent("agent:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "Duplicate",
      });

      await new Promise((r) => setTimeout(r, 10));

      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.messages?.length,
        1,
      );
    });
  });

  describe("agent chat:error events", () => {
    it("should handle chat:error event - set status, message, and clear partial", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Streaming",
      };

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:agent-1", "chat:error", {
        content: "Model unavailable",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.status, "error");
        assert.strictEqual(cache?.error, "Model unavailable");
        assert.strictEqual(cache?.partial, null);
      });
    });
  });

  describe("leaveAgent", () => {
    it("should disconnect agent and remove channel reference", async () => {
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      leaveAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "disconnected",
        );
      });

      let errorCalled = false;
      createAgent(
        "gpt-4",
        1,
        null,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("sendMessage", () => {
    it("should call onError when not connected to agent", async () => {
      let errorCalled = false;
      sendMessage("agent-1", "Hello", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should handle successful message send - add user message, set partial, and waiting", async () => {
      setNextJoinResult("agent:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:agent-1", "chat:message", { ok: {} });

      sendMessage("agent-1", "Hello");

      const cache = useStore.getState().agentsCache["agent-1"];
      assert.strictEqual(cache.messages.length, 1);
      assert.strictEqual(cache.messages[0].role, "user");
      assert.strictEqual(cache.messages[0].content, "Hello");
      assert.strictEqual(cache.partial?.index, 1);
      assert.strictEqual(cache.partial?.role, "assistant");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.waitingForResponse,
          true,
        );
      });
    });

    it("should handle message send error - clear partial and call onError", async () => {
      setNextJoinResult("agent:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:agent-1", "chat:message", {
        error: { reason: "rate_limited" },
      });

      let errorCalled = false;
      sendMessage("agent-1", "Hello", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial,
          null,
        );
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("createAgent", () => {
    it("should call onError when not connected to lobby", async () => {
      let errorCalled = false;
      createAgent(
        "gpt-4",
        1,
        null,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should call onOk with agent ID on create success", async () => {
      setNextPushResult("lobby", "create_agent", { ok: { id: "new-agent" } });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let okCalled = false;
      let agentId = null;
      createAgent("gpt-4", 1, null, (id) => {
        okCalled = true;
        agentId = id;
      });

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
      assert.strictEqual(agentId, "new-agent");
    });

    it("should call onError on create failure", async () => {
      setNextPushResult("lobby", "create_agent", {
        error: { reason: "limit_reached" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let errorCalled = false;
      createAgent(
        "gpt-4",
        1,
        null,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("deleteAgent", () => {
    it("should call onError when not connected to lobby", async () => {
      let errorCalled = false;
      deleteAgent("agent-1", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should call onError on delete failure", async () => {
      setNextPushResult("lobby", "delete_agent", {
        error: { reason: "not_found" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let errorCalled = false;
      deleteAgent("agent-1", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("sync behavior", () => {
    it("should sync messages, partial, status, and lastIndex from sync response", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [{ index: 0, role: "user", content: "Hello" }],
      });

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [
          { index: 1, role: "assistant", content: "Response 1" },
          { index: 2, role: "user", content: "Question" },
          { index: 3, role: "assistant", content: "Response 2" },
        ],
        partial: { index: 4, role: "assistant", content: "Streaming..." },
        status: "streaming",
        messageCount: 3,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      assert.strictEqual(cache.messages.length, 4);
      assert.deepStrictEqual(cache.messages[3], {
        index: 3,
        role: "assistant",
        content: "Response 2",
      });
      assert.deepStrictEqual(cache.partial, {
        index: 4,
        role: "assistant",
        content: "Streaming...",
        charsReceived: 0,
      });
      assert.strictEqual(cache.status, "streaming");
      assert.strictEqual(cache.lastIndex, 3);
    });
  });

  describe("chat:delta gap detection via server event", () => {
    it("should trigger sync when server sends delta with gap", async () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      joinAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up partial with some content
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Simulate server sending delta with a gap (charsStart=5 > charsReceived=3)
      simulateServerEvent("agent:agent-1", "chat:delta", {
        index: 0,
        content: "lo",
        charsStart: 5, // Gap from 3 to 5
        charsEnd: 7,
      });

      await vi.waitFor(() => {
        // Should have logged a warning about the gap
        assert.strictEqual(warnSpy.mock.calls.length > 0, true);
      });

      const warningMessage = warnSpy.mock.calls.find((call) =>
        call[0]?.includes("Delta gap"),
      );
      assert.ok(warningMessage, "Expected warning message about delta gap");

      warnSpy.mockRestore();
    });
  });
});
