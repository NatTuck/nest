/**
 * Shell-job panel.
 *
 * Renders the agent's shell jobs (from the `shell:jobs` channel event /
 * init payload): every `shell-cmd` call while it runs, and each
 * `background: true` job after the call that started it returned. Kill and
 * refresh actions, and an expandable log viewer. Renders nothing when there
 * are no jobs (there is nothing the agent did to show).
 *
 * Only the running jobs are shown up front (#181): a finished job is a
 * transcript entry, and a tail of them pushed the live one off the top. They
 * are collapsed behind one `▸ N finished` row rather than hidden — expanding
 * it shows the same rows, with the same log viewer.
 *
 * `showTitle` is turned off when the panel is embedded in the chat
 * page's jobs tab, where the tab label already carries the title and
 * the job count; the refresh action stays.
 *
 * `showAgent` names each row's owning agent — the space-wide view
 * (`SpaceJobsPanel`, #225) renders one list for every agent in the space, so
 * a row without a name would not say whose job it is. A row whose `agent` is
 * missing shows an explicit marker rather than nothing: the wire contract
 * always carries the name, so its absence is a defect to surface, not hide.
 * `title` names the list ("Shell jobs" by default, "Space jobs" for the
 * space-wide view). `emptyText` is what an empty list says: unset, the panel
 * renders nothing (the chat tab has its own empty line); set, the card stays
 * with that sentence — the space view's "no shell jobs" is a known empty
 * read, not a missing one.
 */

import { useEffect, useState } from "react";
import { finishedJobs, runningJobs } from "../utils/shellJobs";

function statusLabel(job) {
  if (job.status === "running") return "running";
  if (job.killed) return `killed (exit ${job.exit_code})`;
  return `exited ${job.exit_code}`;
}

function statusColor(job) {
  if (job.status === "running") return "text-amber-700";
  if (job.killed) return "text-red-700";
  return job.exit_code === 0 ? "text-green-700" : "text-red-700";
}

function JobRow({ job, open, log, logError, onToggleLog, onKill, showAgent }) {
  return (
    <li className="px-3 py-2 text-sm">
      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0">
          {showAgent &&
            (job.agent ? (
              <span className="mr-2 rounded bg-gray-200 px-1.5 py-0.5 font-mono text-xs text-gray-700">
                {job.agent}
              </span>
            ) : (
              <span className="mr-2 rounded bg-red-100 px-1.5 py-0.5 text-xs font-medium text-red-700">
                unknown agent
              </span>
            ))}
          <span className={`font-medium ${statusColor(job)}`}>
            {statusLabel(job)}
          </span>
          <span className="ml-2 font-mono text-xs text-gray-500">{job.id}</span>
          <span className="ml-2 break-all font-mono text-xs text-gray-800">
            {job.command}
          </span>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <button
            type="button"
            onClick={() => onToggleLog(job.id)}
            className="rounded px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50"
          >
            {open ? "Hide log" : "View log"}
          </button>
          {job.status === "running" && (
            <button
              type="button"
              onClick={() => onKill(job.id)}
              className="rounded px-2 py-0.5 text-xs text-red-600 hover:bg-red-50"
            >
              Kill
            </button>
          )}
        </div>
      </div>
      {open && (
        <div className="mt-2">
          {logError ? (
            <p className="text-xs text-red-600">{logError}</p>
          ) : log === null ? (
            <p className="text-xs text-gray-500">Loading log…</p>
          ) : (
            <pre className="max-h-48 overflow-auto rounded bg-white p-2 text-xs whitespace-pre-wrap">
              {log || "[no output]"}
            </pre>
          )}
        </div>
      )}
    </li>
  );
}

export function ShellJobsPanel({
  jobs = [],
  onKill,
  onOpenLog,
  onRefresh = () => {},
  showTitle = true,
  showAgent = false,
  title = "Shell jobs",
  emptyText = null,
}) {
  const [openId, setOpenId] = useState(null);
  const [log, setLog] = useState(null);
  const [logError, setLogError] = useState(null);
  const [actionError, setActionError] = useState(null);
  const [showFinished, setShowFinished] = useState(false);

  // When the job whose log is open disappears (trimmed, killed, agent
  // stopped), drop the now-dangling viewer state.
  useEffect(() => {
    if (openId && !jobs.some((job) => job.id === openId)) {
      setOpenId(null);
      setLog(null);
      setLogError(null);
    }
  }, [jobs, openId]);

  if (jobs.length === 0 && !emptyText) return null;

  const running = runningJobs(jobs);
  const finished = finishedJobs(jobs);

  const toggleLog = (id) => {
    if (openId === id) {
      setOpenId(null);
      setLog(null);
      setLogError(null);
      return;
    }

    setOpenId(id);
    setLog(null);
    setLogError(null);

    Promise.resolve(onOpenLog(id))
      .then((content) => setLog(content ?? ""))
      .catch((err) => setLogError(err?.message || "Failed to load log"));
  };

  const handleKill = (id) => {
    setActionError(null);
    Promise.resolve(onKill(id)).catch((err) =>
      setActionError(err?.message || "Failed to kill job"),
    );
  };

  const handleRefresh = () => {
    setActionError(null);
    Promise.resolve(onRefresh()).catch((err) =>
      setActionError(err?.message || "Failed to refresh jobs"),
    );
  };

  const row = (job) => (
    <JobRow
      key={job.id}
      job={job}
      open={openId === job.id}
      log={log}
      logError={logError}
      onToggleLog={toggleLog}
      onKill={handleKill}
      showAgent={showAgent}
    />
  );

  return (
    <div className="mb-4 rounded-lg border border-gray-200 bg-gray-50">
      <div
        className={`flex items-center px-3 py-2 ${
          showTitle ? "justify-between" : "justify-end"
        }`}
      >
        {showTitle && (
          <span className="text-sm font-medium text-gray-700">
            {title} ({running.length})
          </span>
        )}
        <button
          type="button"
          onClick={handleRefresh}
          className="rounded px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50"
        >
          Refresh
        </button>
      </div>
      {actionError && (
        <p className="px-3 pb-2 text-xs text-red-600">{actionError}</p>
      )}
      {jobs.length === 0 ? (
        <p className="px-3 pb-2 text-sm text-gray-400">{emptyText}</p>
      ) : (
        <ul className="divide-y divide-gray-200">
          {running.map(row)}
          {finished.length > 0 && (
            <li className="px-3 py-1.5">
              <button
                type="button"
                onClick={() => setShowFinished((shown) => !shown)}
                aria-expanded={showFinished}
                className="w-full rounded text-left text-xs font-medium text-gray-600 hover:text-gray-900"
              >
                {showFinished ? "▾" : "▸"} {finished.length} finished
              </button>
            </li>
          )}
          {showFinished && finished.map(row)}
        </ul>
      )}
    </div>
  );
}
