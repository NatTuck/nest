/**
 * Tests for the space-wide job view's transport (`channels/spaceJobs.js`,
 * #225): the lobby frames that fill the cache and the three pushes that act on
 * any agent's jobs in one space.
 *
 * The cache is the store's `spaceJobs`, keyed by space id; the panel renders
 * it. A frame replaces a space's whole list — that is what makes a job dying
 * with its namespace holder (#224) leave the list without any agent channel.
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
  fetchSpaceJobLog,
  joinLobby,
  killSpaceJob,
  leaveLobby,
  refreshSpaceJobs,
} from "../channels";

const job = (overrides) => ({
  id: "job-1",
  agent: "worker",
  command: "sleep 30",
  status: "running",
  exit_code: null,
  killed: false,
  log_path: "/tmp/worker/shell-jobs/job-1.log",
  ...overrides,
});

const join = () => {
  setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
  joinLobby();
};

describe("the space-wide job view's transport", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  it("init seeds one list per visible space, empty ones included", async () => {
    setNextJoinResult("lobby", {
      autoInit: {
        agents: [],
        space_jobs: [
          { space_id: 1, jobs: [job({})] },
          { space_id: 2, jobs: [] },
        ],
      },
    });
    joinLobby();

    await vi.waitFor(() => {
      assert.strictEqual(useStore.getState().spaceJobs[1]?.length, 1);
    });
    expect(useStore.getState().spaceJobs[1][0].id).toBe("job-1");
    // A known empty space is an entry: the panel says "no jobs", not "loading".
    expect(useStore.getState().spaceJobs[2]).toEqual([]);
  });

  it("a space:jobs frame replaces the space's list — holder-death marking included", async () => {
    join();

    simulateServerEvent("lobby", "space:jobs", {
      space_id: 1,
      jobs: [job({})],
    });
    await vi.waitFor(() => {
      assert.strictEqual(useStore.getState().spaceJobs[1]?.length, 1);
    });

    // The namespace-lost marking (#224): the job died with the space's holder,
    // killed at 137. The frame is an ordinary replace — the view needs no
    // special case for it.
    simulateServerEvent("lobby", "space:jobs", {
      space_id: 1,
      jobs: [job({ status: "exited", killed: true, exit_code: 137 })],
    });
    await vi.waitFor(() => {
      assert.strictEqual(useStore.getState().spaceJobs[1][0].status, "exited");
    });
    expect(useStore.getState().spaceJobs[1][0].killed).toBe(true);
    expect(useStore.getState().spaceJobs[1][0].exit_code).toBe(137);

    // A frame without a list (or without a space) is a contract violation, not
    // an empty space: it changes nothing rather than erasing what the last good
    // frame said. The valid frame for space 2 is the barrier — the mock delivers
    // in schedule order, so its arrival means both bad frames were handled.
    simulateServerEvent("lobby", "space:jobs", { space_id: 1 });
    simulateServerEvent("lobby", "space:jobs", { jobs: [] });
    simulateServerEvent("lobby", "space:jobs", { space_id: 2, jobs: [] });
    await vi.waitFor(() => {
      assert.ok(useStore.getState().spaceJobs[2]);
    });
    expect(useStore.getState().spaceJobs[1]).toHaveLength(1);
    expect(useStore.getState().spaceJobs[1][0].exit_code).toBe(137);
  });

  it("refreshSpaceJobs pushes the space and stores the reply", async () => {
    join();
    setNextPushResult("lobby", "space_jobs", { ok: { jobs: [job({})] } });

    const captured = captureNextPush("lobby", "space_jobs");
    const reply = refreshSpaceJobs(1);

    assert.deepStrictEqual(await captured, { space_id: 1 });
    assert.deepStrictEqual(await reply, [job({})]);
    expect(useStore.getState().spaceJobs[1][0].id).toBe("job-1");
  });

  it("refresh reports a refusal or a missing lobby, and stores nothing", async () => {
    join();
    setNextPushResult("lobby", "space_jobs", {
      error: { reason: "forbidden" },
    });

    await expect(refreshSpaceJobs(1)).rejects.toEqual({ reason: "forbidden" });
    expect(useStore.getState().spaceJobs[1]).toBeUndefined();

    leaveLobby();
    await expect(refreshSpaceJobs(1)).rejects.toThrow(/not connected/i);
  });

  it("killSpaceJob pushes the job's id and resolves with its owner", async () => {
    join();
    setNextPushResult("lobby", "kill_space_job", { ok: { agent: "worker" } });

    const captured = captureNextPush("lobby", "kill_space_job");
    const reply = killSpaceJob(1, "job-1");

    assert.deepStrictEqual(await captured, { space_id: 1, id: "job-1" });
    assert.deepStrictEqual(await reply, { agent: "worker" });

    leaveLobby();
    await expect(killSpaceJob(1, "job-1")).rejects.toThrow(/not connected/i);
  });

  it("fetchSpaceJobLog pushes the job's id and resolves with the log", async () => {
    join();
    setNextPushResult("lobby", "space_job_log", { ok: { content: "hello\n" } });

    const captured = captureNextPush("lobby", "space_job_log");
    const reply = fetchSpaceJobLog(1, "job-1");

    assert.deepStrictEqual(await captured, { space_id: 1, id: "job-1" });
    assert.strictEqual(await reply, "hello\n");

    leaveLobby();
    await expect(fetchSpaceJobLog(1, "job-1")).rejects.toThrow(
      /not connected/i,
    );
  });
});
