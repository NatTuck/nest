/**
 * Coverage for the `:needs_repair` channel paths in
 * `channels/agent.js`: status/init extras, the reload push, and
 * `resetAgentConversation`.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  simulateServerEvent,
} from "./__mocks__/phoenix";
import { useStore } from "./store";
import {
  clearAgentChannels,
  joinAgent,
  leaveLobby,
  reloadAgent,
} from "./channels";

const TOPIC = "agent:1:agent-1";

describe("channels needs_repair", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  it("forwards sequenceViolations and repairCommand from chat:status", async () => {
    joinAgent("agent-1", 1);

    simulateServerEvent(TOPIC, "chat:status", {
      status: "needs_repair",
      sequenceViolations: [{ rule: "tool_pairing" }],
      repairCommand: "mix nest.repair_messages --space clever-raven",
    });

    await vi.waitFor(() => {
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("needs_repair");
      expect(cache.sequenceViolations).toEqual([{ rule: "tool_pairing" }]);
      expect(cache.repairCommand).toBe(
        "mix nest.repair_messages --space clever-raven",
      );
    });
  });

  it("stores the extras from a needs_repair init payload", async () => {
    setNextJoinResult(TOPIC, {
      autoInit: {
        name: "agent-1",
        messageCount: 0,
        status: "needs_repair",
        sequenceViolations: [{ rule: "no_trailing_orphan" }],
        repairCommand: "mix nest.repair_messages --space clever-raven",
      },
    });

    joinAgent("agent-1", 1);

    await vi.waitFor(() => {
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("needs_repair");
      expect(cache.repairCommand).toBe(
        "mix nest.repair_messages --space clever-raven",
      );
    });
  });

  it("resets the conversation and rejoins on a successful reload", async () => {
    joinAgent("agent-1", 1);
    setNextPushResult(TOPIC, "reload_agent", { ok: {} });

    reloadAgent("agent-1", 1);

    await vi.waitFor(() => {
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages).toEqual([]);
      expect(cache.lastIndex).toBe(-1);
    });
  });

  it("surfaces a reload push error via the callback", async () => {
    joinAgent("agent-1", 1);
    setNextPushResult(TOPIC, "reload_agent", {
      error: { reason: "agent_not_found" },
    });
    const onError = vi.fn();

    reloadAgent("agent-1", 1, onError);

    await vi.waitFor(() => {
      expect(onError).toHaveBeenCalledWith({ reason: "agent_not_found" });
    });
  });

  it("reports an error when reloading a disconnected agent", () => {
    const onError = vi.fn();

    reloadAgent("missing-agent", 1, onError);

    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0][0]).toBeInstanceOf(Error);
  });
});
