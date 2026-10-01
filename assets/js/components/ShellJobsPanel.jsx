/**
 * Background shell-job panel.
 *
 * Renders the agent's `shell-cmd background: true` jobs (from the
 * `shell:jobs` channel event / init payload), with kill and refresh
 * actions and an expandable log viewer. Renders nothing when there are
 * no jobs (there is nothing the agent did to show).
 */

import { useEffect, useState } from "react";

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

export function ShellJobsPanel({
  jobs = [],
  onKill,
  onOpenLog,
  onRefresh = () => {},
}) {
  const [openId, setOpenId] = useState(null);
  const [log, setLog] = useState(null);
  const [logError, setLogError] = useState(null);
  const [actionError, setActionError] = useState(null);

  // When the job whose log is open disappears (trimmed, killed, agent
  // stopped), drop the now-dangling viewer state.
  useEffect(() => {
    if (openId && !jobs.some((job) => job.id === openId)) {
      setOpenId(null);
      setLog(null);
      setLogError(null);
    }
  }, [jobs, openId]);

  if (jobs.length === 0) return null;

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

  return (
    <div className="mb-4 rounded-lg border border-gray-200 bg-gray-50">
      <div className="flex items-center justify-between px-3 py-2">
        <span className="text-sm font-medium text-gray-700">
          Background jobs ({jobs.length})
        </span>
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
      <ul className="divide-y divide-gray-200">
        {jobs.map((job) => (
          <li key={job.id} className="px-3 py-2 text-sm">
            <div className="flex items-center justify-between gap-2">
              <div className="min-w-0">
                <span className={`font-medium ${statusColor(job)}`}>
                  {statusLabel(job)}
                </span>
                <span className="ml-2 font-mono text-xs text-gray-500">
                  {job.id}
                </span>
                <span className="ml-2 break-all font-mono text-xs text-gray-800">
                  {job.command}
                </span>
              </div>
              <div className="flex shrink-0 items-center gap-2">
                <button
                  type="button"
                  onClick={() => toggleLog(job.id)}
                  className="rounded px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50"
                >
                  {openId === job.id ? "Hide log" : "View log"}
                </button>
                {job.status === "running" && (
                  <button
                    type="button"
                    onClick={() => handleKill(job.id)}
                    className="rounded px-2 py-0.5 text-xs text-red-600 hover:bg-red-50"
                  >
                    Kill
                  </button>
                )}
              </div>
            </div>
            {openId === job.id && (
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
        ))}
      </ul>
    </div>
  );
}
