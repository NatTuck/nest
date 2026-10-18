/**
 * Tests for the space feed's transport (`channels/spaceNotes.js`).
 *
 * Two pushes and their replies: the read that fills the feed, and the send that
 * is one query. Both are thin, and both have the same rule — a failure is
 * reported on the feed rather than swallowed, so a page that could not load or
 * send never looks like a page with nothing to say.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import assert from "node:assert";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  captureNextPush,
} from "../__mocks__/phoenix";
import { useStore } from "../store";
import {
  clearAgentChannels,
  joinLobby,
  leaveLobby,
  requestSpaceFeed,
  sendSpaceNote,
} from "../channels";

const note = (overrides) => ({
  id: 1,
  space_id: 1,
  from_kind: "agent",
  from_name: "boss",
  to_kind: "user",
  to_name: "alice",
  content: "which one?",
  kind: "query",
  inserted_at: "2026-10-18T12:00:00.000000Z",
  answered_at: null,
  ...overrides,
});

const feed = () => useStore.getState().spaceFeeds[1];

describe("the space feed's transport", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  it("marks the lobby joined, which is when the feed's read can go out", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });

    joinLobby();

    // The socket's handshake is not enough: a push sent before the join is
    // answered is refused, so the flag follows the join's own reply.
    expect(useStore.getState().lobbyJoined).toBe(false);
    await vi.waitFor(() => {
      assert.strictEqual(useStore.getState().lobbyJoined, true);
    });

    leaveLobby();
    expect(useStore.getState().lobbyJoined).toBe(false);
  });

  it("reads the space's feed and stores the whole reply", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();
    setNextPushResult("lobby", "space_feed", {
      ok: {
        notes: [note({})],
        modes: ["plan", "act"],
        default_mode: "plan",
      },
    });

    const captured = captureNextPush("lobby", "space_feed");
    requestSpaceFeed(1);

    assert.deepStrictEqual(await captured, { space_id: 1 });
    await vi.waitFor(() => {
      assert.strictEqual(feed().status, "ready");
    });
    expect(feed().notes).toHaveLength(1);
    expect(feed().modes).toEqual(["plan", "act"]);
    expect(feed().defaultMode).toBe("plan");
  });

  it("says the read failed — naming the reason — rather than showing an empty feed", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();

    setNextPushResult("lobby", "space_feed", {
      error: { reason: "forbidden" },
    });
    requestSpaceFeed(1);

    await vi.waitFor(() => {
      assert.strictEqual(feed().status, "error");
    });
    // The server's own code reaches the page, so the banner is not generic.
    expect(feed().error).toContain("forbidden");
    expect(feed().notes).toEqual([]);
  });

  it("says the read failed when the server never answers", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();
    setNextPushResult("lobby", "space_feed", { timeout: true });

    requestSpaceFeed(1);

    await vi.waitFor(() => {
      assert.strictEqual(feed().status, "error");
    });
    expect(feed().error).toMatch(/did not answer/i);
  });

  it("says the read failed when there is no lobby to ask", () => {
    // No join at all: the page must not sit on a spinner forever.
    requestSpaceFeed(1);

    expect(feed().status).toBe("error");
    expect(feed().error).toMatch(/not connected/i);
  });

  it("sends one query and answers that agent's outstanding queries", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();
    useStore
      .getState()
      .setSpaceFeed(1, { notes: [note({})], modes: ["plan", "act"] });
    setNextPushResult("lobby", "send_note", { ok: { disposition: "queued" } });

    const captured = captureNextPush("lobby", "send_note");
    const reply = vi.fn();
    sendSpaceNote(1, "boss", "the second one", "plan", reply);

    assert.deepStrictEqual(await captured, {
      space_id: 1,
      to: "boss",
      content: "the second one",
      mode: "plan",
    });
    await vi.waitFor(() => {
      assert.strictEqual(reply.mock.calls.length, 1);
    });
    // The send is the banner's clear: the server marks it answered and does not
    // broadcast that, so the feed applies the action it just performed.
    expect(feed().notes[0].answered_at).toEqual(expect.any(String));
  });

  it("sends no mode when the draft has none, rather than inventing one", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();

    const captured = captureNextPush("lobby", "send_note");
    const reply = vi.fn();
    sendSpaceNote(1, "boss", "hi", null, reply);

    assert.deepStrictEqual(await captured, {
      space_id: 1,
      to: "boss",
      content: "hi",
    });
    // The reply is awaited so the send's own effects have landed before this
    // test ends: the mock answers asynchronously, and an un-awaited one would
    // reach into the next test's store.
    await vi.waitFor(() => {
      assert.strictEqual(reply.mock.calls.length, 1);
    });
  });

  it("reports a refused send, and leaves the owed-reply banner alone", async () => {
    setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
    joinLobby();
    useStore.getState().setSpaceFeed(1, { notes: [note({})], modes: [] });
    setNextPushResult("lobby", "send_note", {
      error: { reason: "agent_not_found", target: "boss" },
    });

    const onError = vi.fn();
    sendSpaceNote(1, "boss", "hi", "plan", undefined, onError);

    await vi.waitFor(() => {
      assert.strictEqual(onError.mock.calls.length, 1);
    });
    expect(onError.mock.calls[0][0]).toEqual({
      reason: "agent_not_found",
      target: "boss",
    });
    // Nothing was answered, because nothing was sent.
    expect(feed().notes[0].answered_at).toBeNull();
  });

  it("reports a send that could not be attempted", () => {
    const onError = vi.fn();

    sendSpaceNote(1, "boss", "hi", "plan", undefined, onError);

    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0][0].message).toMatch(/not connected/i);
  });
});
