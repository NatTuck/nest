/**
 * Tests for the pane's transport (`channels/pane.js`): the join's `pane:sync`
 * that restores the pane on a reload, the `pane:state` frame, and the three
 * pushes that act on a question.
 *
 * The transport's job is narrow and worth pinning: it posts exactly what the
 * user did, applies the reply to the store, and reports a push that could not
 * land on the pane itself rather than leaving a button that silently did
 * nothing.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import assert from "node:assert";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  captureNextPush,
  simulateServerEvent,
} from "../__mocks__/phoenix";
import { useStore } from "../store";
import {
  clearAgentChannels,
  dropDecisions,
  explainDecision,
  joinAgent,
  requestPaneSync,
  sendDecisionAnswers,
} from "../channels";

const TOPIC = "agent:1:agent-1";

const decision = (overrides) => ({
  id: "d1",
  title: "Ship or wait?",
  body: "body",
  options: ["Ship", "Wait"],
  askedBy: "boss",
  obsolete: false,
  obsoleteReason: null,
  orphaned: false,
  orphanedReason: null,
  ...overrides,
});

const frame = (seq, decisions = []) => ({
  spaceId: 1,
  decisions,
  todos: {},
  seq,
});

const pane = () => useStore.getState().panes[1];

describe("the pane's transport", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    vi.restoreAllMocks();
  });

  it("restores the pane from the join's pane:sync", async () => {
    setNextPushResult(TOPIC, "pane:sync", {
      ok: frame(3, [decision({})]),
    });
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });

    joinAgent("agent-1", 1);

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.seq, 3);
    });
    expect(pane().decisions.map((held) => held.id)).toEqual(["d1"]);
  });

  it("sends a pane:sync reply that is not a frame to the store, which refuses it out loud", async () => {
    // The store is the one place that decides a payload is unusable. A helper
    // that dropped it first would leave a reload with a permanently empty pane
    // and a clean console — the one signal that the two sides disagree.
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    setNextPushResult(TOPIC, "pane:sync", { ok: {} });
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });

    joinAgent("agent-1", 1);

    await vi.waitFor(() => {
      assert.strictEqual(warn.mock.calls.length, 1);
    });
    // Nothing was cached, so the pane is still waiting for a real frame.
    expect(useStore.getState().panes[1]).toBeUndefined();
    expect(String(warn.mock.calls[0][0])).toContain(
      "unusable pane:state frame",
    );

    simulateServerEvent(TOPIC, "pane:state", frame(1, [decision({})]));

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.decisions.length, 1);
    });
    expect(pane().seq).toBe(1);
  });

  it("refuses a pane frame that names another space", async () => {
    // The channel's space is the key; a payload that disagrees is a
    // cross-space broadcast bug, and filing it under either space would leave
    // the bug in place and invisible. The join's own sync left the pane at
    // `seq: 0`, so this frame is newer than it — a client that did not check
    // the space would apply it, which is what makes this able to fail.
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });
    joinAgent("agent-1", 1);

    simulateServerEvent(TOPIC, "pane:state", {
      ...frame(1, [decision({})]),
      spaceId: 2,
    });

    await vi.waitFor(() => {
      assert.strictEqual(warn.mock.calls.length, 1);
    });
    expect(pane()?.decisions).toEqual([]);
    expect(useStore.getState().panes[2]).toBeUndefined();
    expect(String(warn.mock.calls[0][0])).toContain("space 2");
  });

  it("stores a pane:state frame pushed after the join", async () => {
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });
    joinAgent("agent-1", 1);

    simulateServerEvent(TOPIC, "pane:state", frame(2, [decision({})]));

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.decisions.length, 1);
    });
    expect(pane().todos).toEqual({});
  });

  it("posts the answers and applies the reply's reports", async () => {
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });
    joinAgent("agent-1", 1);
    useStore
      .getState()
      .setPaneState(
        1,
        frame(1, [
          decision({ id: "d1" }),
          decision({ id: "d2" }),
          decision({ id: "d3" }),
          decision({ id: "d4" }),
        ]),
      );
    setNextPushResult(TOPIC, "decisions:answer", {
      ok: {
        delivered: ["d1"],
        orphaned: [{ id: "d2", reason: "the agent is archived" }],
        failed: [{ id: "d3", reason: "the agent is busy" }],
        lost: [{ id: "d4", reason: "the agent vanished" }],
      },
    });

    const captured = captureNextPush(TOPIC, "decisions:answer");
    sendDecisionAnswers("agent-1", 1, [{ id: "d1", answer: "Ship" }]);

    assert.deepStrictEqual(await captured, {
      answers: [{ id: "d1", answer: "Ship" }],
    });
    await vi.waitFor(() => {
      assert.strictEqual(pane()?.outcomes.d4?.kind, "lost");
    });
    expect(pane().outcomes.d2).toEqual({
      kind: "orphaned",
      reason: "the agent is archived",
    });
    expect(pane().outcomes.d3).toEqual({
      kind: "failed",
      reason: "the agent is busy",
    });
    expect(pane().error).toBeNull();
    // Every question is still in the list: the server's frame is the removal.
    expect(pane().decisions).toHaveLength(4);
  });

  it("posts the ids to drop and the one to explain, and marks the explain", async () => {
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });
    joinAgent("agent-1", 1);
    useStore.getState().setPaneState(1, frame(1, [decision({})]));

    setNextPushResult(TOPIC, "decisions:drop", { ok: {} });
    const dropped = captureNextPush(TOPIC, "decisions:drop");
    dropDecisions("agent-1", 1, ["d1"]);

    assert.deepStrictEqual(await dropped, { ids: ["d1"] });

    setNextPushResult(TOPIC, "decisions:explain", { ok: {} });
    const explained = captureNextPush(TOPIC, "decisions:explain");
    explainDecision("agent-1", 1, "d1");

    assert.deepStrictEqual(await explained, { id: "d1" });
    // The question stays open, and the click is acknowledged on it.
    await vi.waitFor(() => {
      assert.strictEqual(pane()?.outcomes.d1?.kind, "explained");
    });
    expect(pane().decisions).toHaveLength(1);
  });

  it("reports a push that could not land on the pane rather than swallowing it", async () => {
    setNextJoinResult(TOPIC, { autoInit: { status: "idle" } });
    joinAgent("agent-1", 1);
    useStore.getState().setPaneState(1, frame(1, [decision({})]));

    setNextPushResult(TOPIC, "decisions:answer", {
      error: { reason: "forbidden" },
    });
    sendDecisionAnswers("agent-1", 1, [{ id: "d1", answer: "Ship" }]);

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.error, "forbidden");
    });

    setNextPushResult(TOPIC, "decisions:drop", { timeout: true });
    dropDecisions("agent-1", 1, ["d1"]);

    await vi.waitFor(() => {
      assert.match(pane()?.error ?? "", /timed out/i);
    });

    setNextPushResult(TOPIC, "decisions:drop", { error: { reason: "gone" } });
    dropDecisions("agent-1", 1, ["d1"]);

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.error, "gone");
    });

    setNextPushResult(TOPIC, "decisions:explain", { timeout: true });
    explainDecision("agent-1", 1, "d1");

    await vi.waitFor(() => {
      assert.match(pane()?.error ?? "", /timed out/i);
    });

    setNextPushResult(TOPIC, "decisions:explain", { error: {} });
    explainDecision("agent-1", 1, "d1");

    // A refusal with no reason still says what the click was trying to do.
    await vi.waitFor(() => {
      assert.match(pane()?.error ?? "", /more detail/i);
    });

    setNextPushResult(TOPIC, "decisions:explain", {
      error: { reason: "agent_archived" },
    });
    explainDecision("agent-1", 1, "d1");

    await vi.waitFor(() => {
      assert.strictEqual(pane()?.error, "agent_archived");
    });

    setNextPushResult(TOPIC, "decisions:answer", { timeout: true });
    sendDecisionAnswers("agent-1", 1, [{ id: "d1", answer: "Ship" }]);

    await vi.waitFor(() => {
      assert.match(pane()?.error ?? "", /answers timed out/i);
    });
  });

  it("reports a pane push made with no channel, and does not throw", () => {
    // No join at all: the pane must say why the click did nothing.
    useStore.getState().setPaneState(1, frame(1, [decision({})]));

    requestPaneSync("agent-1", 1);
    sendDecisionAnswers("agent-1", 1, [{ id: "d1", answer: "Ship" }]);

    expect(pane().error).toMatch(/not connected/i);

    dropDecisions("agent-1", 1, ["d1"]);
    explainDecision("agent-1", 1, "d1");

    expect(pane().error).toMatch(/not connected/i);
    expect(pane().outcomes).toEqual({});
  });
});
