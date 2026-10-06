/**
 * Background shell-job actions over the agent channel (kill / list /
 * log). Split out of `channels/agent.js` to stay under the
 * source-line cap.
 */

import { agentChannels, getStore } from "./state";

/**
 * Kill one of the agent's background shell jobs. Resolves when the
 * server acknowledges, or rejects with the server error. `onError` is
 * still called (for callback-style callers). Rejects when the channel
 * isn't connected.
 */
export function killShellJob(agentId, id, onError) {
  return new Promise((resolve, reject) => {
    const channel = agentChannels.get(agentId);
    if (!channel) {
      const err = new Error("Not connected to agent");
      if (onError) onError(err);
      reject(err);
      return;
    }

    channel
      .push("shell:kill", { id })
      .receive("ok", () => resolve())
      .receive("error", (err) => {
        if (onError) onError(err);
        reject(err);
      });
  });
}

/**
 * Refresh an agent's background-job list over `shell:list`. Updates the
 * store from the reply and resolves with the jobs. Rejects with the
 * server error, or when the channel isn't connected.
 */
export function refreshShellJobs(agentId) {
  return new Promise((resolve, reject) => {
    const channel = agentChannels.get(agentId);
    if (!channel) {
      reject(new Error("Not connected to agent"));
      return;
    }

    channel
      .push("shell:list", {})
      .receive("ok", (resp) => {
        const jobs = resp?.jobs ?? [];
        getStore().setAgentJobs(agentId, jobs);
        resolve(jobs);
      })
      .receive("error", (err) => reject(err));
  });
}

/**
 * Fetch a background job's captured log over `shell:log`. Resolves with
 * the log text, or rejects with the server error. A no-op (rejects)
 * when the channel isn't connected.
 */
export function fetchShellLog(agentId, id) {
  return new Promise((resolve, reject) => {
    const channel = agentChannels.get(agentId);
    if (!channel) {
      reject(new Error("Not connected to agent"));
      return;
    }

    channel
      .push("shell:log", { id })
      .receive("ok", (resp) => resolve(resp?.content ?? ""))
      .receive("error", (err) => reject(err));
  });
}
