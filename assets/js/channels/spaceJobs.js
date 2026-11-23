/**
 * Space-wide shell-job actions over the lobby channel (#225): refresh, kill
 * and log for any agent's jobs in one space. The per-agent equivalents are
 * `channels/shellJobs.js` (agent channel, owner-scoped); these ride the lobby
 * because the space view has no one agent's channel behind it — the same
 * reason the space feed's read does.
 */

import { getStore, lobbyChannel } from "./state";

/**
 * Refresh one space's job list over `space_jobs`. Updates the store from the
 * reply and resolves with the jobs. Rejects with the server error, or when the
 * lobby isn't connected.
 */
export function refreshSpaceJobs(spaceId) {
  return new Promise((resolve, reject) => {
    if (!lobbyChannel) {
      reject(new Error("Not connected to lobby"));
      return;
    }

    lobbyChannel
      .push("space_jobs", { space_id: spaceId })
      .receive("ok", (resp) => {
        const jobs = resp?.jobs ?? [];
        getStore().setSpaceJobs(spaceId, jobs);
        resolve(jobs);
      })
      .receive("error", (err) => reject(err));
  });
}

/**
 * Kill a running job owned by any agent in the space, over `kill_space_job`.
 * Resolves with the reply (which names the owning agent), or rejects with the
 * server error. The owning agent is notified by the server — a job stopped
 * from the space page is one its owner did not ask to lose.
 */
export function killSpaceJob(spaceId, id) {
  return new Promise((resolve, reject) => {
    if (!lobbyChannel) {
      reject(new Error("Not connected to lobby"));
      return;
    }

    lobbyChannel
      .push("kill_space_job", { space_id: spaceId, id })
      .receive("ok", (resp) => resolve(resp))
      .receive("error", (err) => reject(err));
  });
}

/**
 * Fetch one job's captured log over `space_job_log`, whichever agent in the
 * space owns it. Resolves with the log text, or rejects with the server error.
 */
export function fetchSpaceJobLog(spaceId, id) {
  return new Promise((resolve, reject) => {
    if (!lobbyChannel) {
      reject(new Error("Not connected to lobby"));
      return;
    }

    lobbyChannel
      .push("space_job_log", { space_id: spaceId, id })
      .receive("ok", (resp) => resolve(resp?.content ?? ""))
      .receive("error", (err) => reject(err));
  });
}
