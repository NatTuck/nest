/**
 * The `:needs_repair` banner — shown when the agent's persisted active
 * message sequence failed wire validation at load, so chat is blocked
 * until it is repaired offline. Mirrors `ModelMissingBanner`'s layout,
 * but the recovery is a `mix nest.repair_messages` run followed by a
 * reload (the running process still holds the pre-repair sequence).
 */

import { useCopyToClipboard } from "../utils/clipboard";

export function NeedsRepairBanner({
  violations,
  repairCommand,
  onReload,
  error,
}) {
  const [copied, copy] = useCopyToClipboard();
  const count = Array.isArray(violations) ? violations.length : 0;
  const noun = count === 1 ? "problem" : "problems";

  return (
    <div
      role="alert"
      aria-live="polite"
      className="bg-amber-50 border-l-4 border-amber-500 p-4 mb-4"
    >
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-amber-900 font-medium">
            This conversation needs repair before it can continue
          </p>
          <p className="text-amber-800 text-sm mt-1">
            The persisted message sequence failed validation
            {count > 0 ? ` (${count} ${noun})` : ""}. Chat is disabled until it
            is repaired offline, then reload the agent.
          </p>
          {repairCommand && (
            <div className="mt-2 flex items-center gap-2">
              <code className="font-mono text-xs bg-amber-100 text-amber-900 rounded px-2 py-1 break-all">
                {repairCommand}
              </code>
              <button
                type="button"
                onClick={() => copy(repairCommand)}
                className="flex-shrink-0 px-2 py-1 rounded text-xs font-medium text-amber-900 bg-amber-200 hover:bg-amber-300 active:bg-amber-400 transition-colors"
              >
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          )}
          {error && <p className="text-red-700 text-sm mt-2">{error}</p>}
        </div>
        <button
          type="button"
          onClick={onReload}
          className="flex-shrink-0 px-4 py-2 rounded-lg font-medium text-amber-900 bg-amber-200 hover:bg-amber-300 active:bg-amber-400 transition-colors"
        >
          Reload agent
        </button>
      </div>
    </div>
  );
}
