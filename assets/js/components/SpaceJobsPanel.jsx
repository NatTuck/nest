/**
 * The space-wide shell-job panel (#225): every agent's jobs in one space, on
 * the space's own page — the feed's chrome and the RPG main view alike.
 *
 * The per-agent panel (`ShellJobsPanel` in the chat page's jobs tab) answers
 * "what did this agent run"; this one answers "what is running in this space",
 * including a job a sibling left behind. Its list is the lobby's: the `init`
 * payload seeds one entry per visible space, and `space:jobs` frames replace a
 * space's list whenever any job in it changes — a start, an exit, a kill, or
 * the namespace-lost marking when the space's holder dies (#224). No agent
 * channel is joined to show any of it.
 *
 * Three states, and the panel says which one it is in (the transparency rule):
 * a list that has arrived renders, an empty one says "no shell jobs", and a
 * space with no read yet shows a loading line — or, when the read failed, an
 * explicit error with a retry. Nothing is ever hidden behind a blank.
 *
 * One refresh per visit resyncs what the frames keep current in between (a
 * space created after the lobby joined has no init entry, for one), the same
 * way the feed re-reads its notes on every visit.
 */

import { useCallback, useEffect, useState } from "react";
import { useStore } from "../store";
import { fetchSpaceJobLog, killSpaceJob, refreshSpaceJobs } from "../channels";
import { errorText } from "../utils/errorText";
import { ShellJobsPanel } from "./ShellJobsPanel";

export function SpaceJobsPanel({ spaceId }) {
  const jobs = useStore((state) => state.spaceJobs[spaceId]);
  const lobbyJoined = useStore((state) => state.lobbyJoined);
  const [readError, setReadError] = useState(null);

  // The refresh the button and the visit both use. Its failure is this
  // panel's own state: the list on screen (if any) is still the server's last
  // word, so the error is shown beside it, never instead of it.
  const refresh = useCallback(() => {
    setReadError(null);
    return refreshSpaceJobs(spaceId).catch((err) => {
      setReadError(errorText(err, "Could not load this space's shell jobs."));
    });
  }, [spaceId]);

  useEffect(() => {
    if (!lobbyJoined) return;
    refresh();
  }, [lobbyJoined, refresh]);

  // No read has landed for this space. Until one does, the panel says so —
  // loading while the read is on its way, an explicit error when it failed.
  if (jobs === undefined) {
    return (
      <div className="mb-4 rounded-lg border border-gray-200 bg-gray-50 px-3 py-2">
        {readError ? (
          <div role="alert" className="flex items-center justify-between gap-2">
            <p className="text-sm text-red-600">
              Shell jobs could not be loaded: {readError}
            </p>
            <button
              type="button"
              onClick={refresh}
              className="shrink-0 rounded px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50"
            >
              Try again
            </button>
          </div>
        ) : (
          <p className="text-sm text-gray-500">
            {lobbyJoined
              ? "Loading shell jobs…"
              : "Waiting for the lobby connection…"}
          </p>
        )}
      </div>
    );
  }

  return (
    <>
      {readError && (
        <p role="alert" className="mb-2 text-xs text-red-600">
          Could not refresh shell jobs: {readError}
        </p>
      )}
      <ShellJobsPanel
        jobs={jobs}
        title="Space jobs"
        showAgent
        emptyText="No shell jobs in this space."
        onKill={(id) => killSpaceJob(spaceId, id)}
        onOpenLog={(id) => fetchSpaceJobLog(spaceId, id)}
        onRefresh={refresh}
      />
    </>
  );
}
