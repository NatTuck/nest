/**
 * The `chat:sync` drain, from the client's side.
 *
 * A cold cache for an agent with a long conversation is drained in successive
 * `chat:sync` batches — issue #52 cut the batch count ~16x by raising the
 * reply budget, which makes this the ordinary path rather than an edge. Two
 * properties matter: the recursion asks for the next batch from the watermark
 * the last reply reached, and it terminates.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  captureNextPush,
} from "./__mocks__/phoenix";
import { useStore } from "./store";
import {
  agentChannels,
  clearAgentChannels,
  joinAgent,
  leaveLobby,
} from "./channels";

const TOPIC = "agent:1:agent-1";

function row(index) {
  return {
    index,
    role: index % 2 === 0 ? "user" : "assistant",
    parts: [{ kind: "text", text: `m${index}` }],
  };
}

// A join whose init carries no rows but a larger count, which is what makes
// the client ask for the whole window from -1.
function joinWithEmptyCache() {
  setNextJoinResult(TOPIC, {
    autoInit: {
      id: "agent-1",
      status: "idle",
      messageCount: 4,
      messages: [],
    },
  });

  joinAgent("agent-1", 1);
}

describe("chat:sync drain", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  it("re-syncs from the watermark the reply reached", async () => {
    setNextPushResult(TOPIC, "chat:sync", {
      ok: {
        messages: [row(0), row(1)],
        partial: null,
        status: "idle",
        messageCount: 4,
      },
    });

    const first = captureNextPush(TOPIC, "chat:sync");
    joinWithEmptyCache();
    expect(await first).toEqual({ lastIndex: -1 });

    // The reply moved the watermark to 1, so the next request starts there.
    const second = captureNextPush(TOPIC, "chat:sync");
    expect(await second).toEqual({ lastIndex: 1 });
  });

  it("stops when a reply adds no new index", async () => {
    // Join with the rows already cached, so the rejoin below asks only for
    // the delta from the cached watermark.
    setNextJoinResult(TOPIC, {
      autoInit: {
        id: "agent-1",
        status: "idle",
        messageCount: 2,
        messages: [row(0), row(1)],
      },
    });

    joinAgent("agent-1", 1);

    await vi.waitFor(() => {
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.messages.map((m) => m.index)).toEqual([0, 1]);
    });

    // The rejoin's status reply claims one more row than the cache holds, so
    // the client asks for the delta from watermark 1. The sync reply answers
    // with rows it already has — nothing above the watermark — so there is no
    // progress and the loop has to end instead of re-requesting that batch
    // forever.
    setNextPushResult(TOPIC, "chat:status", {
      ok: { status: "idle", messageCount: 3 },
    });
    setNextPushResult(TOPIC, "chat:sync", {
      ok: {
        messages: [row(0), row(1)],
        partial: null,
        status: "executing_tools",
        messageCount: 3,
      },
    });

    const pushSpy = vi.spyOn(agentChannels.get("agent-1"), "push");
    const syncPush = captureNextPush(TOPIC, "chat:sync");

    joinAgent("agent-1", 1);

    expect(await syncPush).toEqual({ lastIndex: 1 });

    // The reply was processed (its status landed) and the watermark did not
    // move, so exactly one sync request may have been made. A missing guard
    // re-requests from inside the same callback, so the extra push is already
    // on the spy by the time this polls.
    await vi.waitFor(() => {
      const cache = useStore.getState().agentsCache["agent-1"];
      expect(cache.agentState).toBe("executing_tools");
    });

    expect(
      pushSpy.mock.calls.filter(([event]) => event === "chat:sync"),
    ).toEqual([["chat:sync", { lastIndex: 1 }]]);

    pushSpy.mockRestore();
  });
});
