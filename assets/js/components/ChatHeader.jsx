/**
 * Chat agent header: name, model chip (opens the edit dialog), the
 * "back to parent" link, and the token-usage chip + status. Extracted
 * from `ChatPage` to keep that file under the source-line cap.
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
      <div className="flex items-end justify-between gap-4">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-gray-900">
            {name}
            {vocation?.name && (
              <span className="text-gray-500 font-normal">
                ({vocation.name})
              </span>
            )}
          </h1>
          <p className="text-sm text-gray-500 break-all">
            <button
              type="button"
              onClick={onModelPickerOpen}
              aria-label="Change model"
              className={`
                inline-flex items-center gap-1
                px-2 py-0.5 rounded-md
                transition-colors duration-150
                hover:bg-gray-100
                ${
                  agentState === "model_missing"
                    ? "bg-amber-100 text-amber-900 hover:bg-amber-200"
                    : "text-gray-500"
                }
              `}
            >
              <span className="font-mono text-xs">
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
        <div className="flex flex-col items-end gap-2">
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
