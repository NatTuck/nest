/**
 * Chat agent header: name, model chip (opens the edit dialog), the
 * "back to parent" link, and the token-usage chip + status. Extracted
 * from `ChatPage` to keep that file under the source-line cap.
 *
 * Below `lg` it is a column of four short lines — the name, the vocation, the
 * model chip, and the token/status block — because the row it is on a desktop
 * cannot survive 390px: the name, the chip and the token readout competed for
 * one line, the name took three, the chip was crushed to a column of syllables,
 * and the readout (which is one unbreakable line of mono numbers) pushed the
 * whole strip 76px wider than the screen. From `lg` up it is the row it has
 * always been, `items-end` and `justify-between`.
 */

import { Link } from "react-router-dom";
import { TokenUsageChip } from "./TokenUsageChip";

export function ChatHeader({
  name,
  vocation,
  model,
  agentState,
  changeModelError,
  parentName,
  depth,
  spaceSlug,
  usage,
  descendantUsage,
  totalUsage,
  contextLimit,
  status,
  streaming,
  onModelPickerOpen,
  getStatusLabel,
}) {
  return (
    <div className="border-b border-gray-200 pb-4 mb-4">
      <div className="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between lg:gap-4">
        <div className="min-w-0">
          {/* One line, ellipsised: a name like `charming-rhinoceros-root` used
              to take three lines and push everything else down. The full text
              stays in the DOM (an ellipsis does not shorten an accessible name)
              and in `title` for a mouse. The vocation rides on the same line
              from `lg` up, and is its own line below it. */}
          <h1
            className="text-2xl font-bold text-gray-900 max-lg:truncate"
            title={vocation?.name ? `${name} (${vocation.name})` : name}
          >
            {name}
            {vocation?.name && (
              <span className="hidden text-gray-500 font-normal lg:inline">
                {" "}
                ({vocation.name})
              </span>
            )}
          </h1>
          {vocation?.name && (
            <p className="truncate text-sm text-gray-500 lg:hidden">
              {vocation.name}
            </p>
          )}
          <p className="text-sm text-gray-500 break-all">
            <button
              type="button"
              onClick={onModelPickerOpen}
              aria-label="Change model"
              className={`
                inline-flex items-center gap-1
                px-2 py-0.5 rounded-md
                max-lg:min-h-11 max-lg:min-w-40 max-lg:max-w-full
                transition-colors duration-150
                hover:bg-gray-100
                ${
                  agentState === "model_missing"
                    ? "bg-amber-100 text-amber-900 hover:bg-amber-200"
                    : "text-gray-500"
                }
              `}
            >
              <span className="font-mono text-xs max-lg:min-w-0 max-lg:truncate">
                {(() => {
                  const modelName = model?.name;
                  const provider = model?.provider;
                  if (!modelName) return "[missing]";
                  return provider ? `${provider}: ${modelName}` : modelName;
                })()}
              </span>
              <svg
                className="w-3 h-3 opacity-60"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M19 9l-7 7-7-7"
                />
              </svg>
            </button>
            {changeModelError && (
              <span className="ml-2 text-xs text-red-600">
                {changeModelError}
              </span>
            )}
          </p>
          {parentName && (
            <p className="text-xs text-gray-500 mt-1">
              ↑{" "}
              <Link
                to={`/space/${encodeURIComponent(spaceSlug)}/agent/${encodeURIComponent(parentName)}`}
                className="text-blue-600 hover:underline"
              >
                back to {parentName}
              </Link>
              {depth > 0 && (
                <span className="text-gray-400 ml-2">(depth {depth})</span>
              )}
            </p>
          )}
        </div>
        <div className="flex min-w-0 flex-col items-end gap-2 max-lg:w-full">
          <TokenUsageChip
            usage={usage}
            descendantUsage={descendantUsage}
            totalUsage={totalUsage}
            contextLimit={contextLimit}
          />
          <div className="flex items-center gap-2">
            <div
              className={`
                w-3 h-3 rounded-full
                ${status === "connected" ? "bg-green-500" : "bg-gray-300"}
                ${streaming ? "animate-pulse" : ""}
              `}
            />
            <span className="text-sm text-gray-400">{getStatusLabel()}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
