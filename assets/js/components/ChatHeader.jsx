/**
 * Chat agent header: name, model chip (opens the edit dialog), the
 * "back to parent" link, and the token-usage chip + status. Extracted
 * from `ChatPage` to keep that file under the source-line cap.
 *
 * Below `lg` it is **one line** — the name, the status dot and a chevron — and
 * everything else (the vocation, the model chip, the token readout, the
 * readiness label, the parent link) is behind that chevron as a disclosure that
 * starts closed. A phone with a browser toolbar and the OS nav bar has well under
 * 844px to work with, and four stacked lines of header left the transcript about
 * two lines of text; the header is the one part of the chrome that can be folded
 * without losing anything, because every piece of it is reference information
 * rather than something the reader acts on.
 *
 * `max-lg:hidden` is the whole switch: from `lg` up it never applies, so the
 * desktop header is the same markup it has always been, always expanded, with no
 * JS deciding anything about it. Nothing becomes unreachable: a tap opens the
 * same text the desktop shows, and no information is hover-only.
 */

import { useState } from "react";
import { Link } from "react-router-dom";
import { ChevronDown } from "./ChevronDown";
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
  // Closed on every mount, and per agent: the disclosure is a phone convenience,
  // not a preference, so it does not belong in the store.
  const [detailsOpen, setDetailsOpen] = useState(false);
  // Appended to every element the disclosure hides. Inert from `lg` up, which is
  // what keeps the desktop expanded without a second branch.
  const detailClass = detailsOpen ? "" : "max-lg:hidden";

  const dotClass = [
    "w-3 h-3 rounded-full",
    status === "connected" ? "bg-green-500" : "bg-gray-300",
    streaming ? "animate-pulse" : "",
  ].join(" ");

  return (
    <div className="border-b border-gray-200 pb-4 mb-4 max-lg:pb-2 max-lg:mb-2">
      <div className="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between lg:gap-4">
        <div className="min-w-0">
          {/* One line below `lg`; from `lg` up this is a plain block again, so
              the heading is the same box it has always been. The name is clamped
              to two lines: one ellipsised line is not readable either, and a
              phone has no hover to reveal the rest. */}
          <div className="flex items-start gap-2 lg:block">
            <h1 className="min-w-0 text-2xl font-bold text-gray-900 max-lg:line-clamp-2">
              {name}
              {vocation?.name && (
                <span className="hidden text-gray-500 font-normal lg:inline">
                  {" "}
                  ({vocation.name})
                </span>
              )}
            </h1>
            {/* Phone only: the dot is the one piece of the status row that stays
                on the line, so it carries the label for a screen reader (a
                colour alone is not a status). */}
            <div className="flex shrink-0 items-center lg:hidden">
              <span
                role="img"
                aria-label={getStatusLabel()}
                className={`mr-1 ${dotClass}`}
              />
              <button
                type="button"
                onClick={() => setDetailsOpen((open) => !open)}
                aria-expanded={detailsOpen}
                aria-label="Agent details"
                className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-gray-500 transition-colors hover:bg-gray-100 active:bg-gray-200"
              >
                <ChevronDown rotated={detailsOpen} />
              </button>
            </div>
          </div>
          {vocation?.name && (
            <p
              className={`truncate text-sm text-gray-500 lg:hidden ${detailClass}`}
            >
              {vocation.name}
            </p>
          )}
          <p className={`text-sm text-gray-500 break-all ${detailClass}`}>
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
            <p className={`text-xs text-gray-500 mt-1 ${detailClass}`}>
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
            className={detailClass}
          />
          <div className={`flex items-center gap-2 ${detailClass}`}>
            {/* The dot is already on the phone's line; the label is what the
                disclosure adds. */}
            <div className={`${dotClass} max-lg:hidden`} />
            <span className="text-sm text-gray-400">{getStatusLabel()}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
