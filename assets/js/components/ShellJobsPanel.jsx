/**
 * Background shell-job panel.
 *
 * Renders the agent's `shell-cmd background: true` jobs (from the
 * `shell:jobs` channel event / init payload), with a kill action and an
 * expandable log viewer. Renders nothing when there are no jobs (there
 * is nothing the agent did to show).
 */

import { useState } from "react";

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

export function ShellJobsPanel({ jobs = [], onKill, onOpenLog }) {
  const [openId, setOpenId] = useState(null);
  const [log, setLog] = useState(null);
  const [logError, setLogError] = useState(null);

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

  return (
    <div className="mb-4 rounded-lg border border-gray-200 bg-gray-50">
      <div className="px-3 py-2 text-sm font-medium text-gray-700">
        Background jobs ({jobs.length})
      </div>
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
                    onClick={() => onKill(job.id)}
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
