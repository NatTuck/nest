/**
 * ThinkingBlock — collapsible box for the model's thinking /
 * reasoning content. This is the one and only component that
 * renders thinking/reasoning text in the chat UI; the visible
 * reply is rendered by `<MessageContent>`. See `ChatPage.jsx`
 * and `CollapsedHistory.jsx` for callers.
 *
 * The box lives in the same place before and after a turn
 * finalizes. To make that work, the parent passes a `key` prop
 * that changes on the partial→final transition (e.g.
 * `key={isPartial ? "partial" : "final"}`). That re-mounts the
 * box, which re-initializes `useState(isPartial)` to its new
 * value:
 *
 *   * `isPartial: true`  — the box starts **expanded** so the
 *     user can watch the reasoning stream in. The bouncing-dots
 *     indicator in the header shows the model is still writing.
 *   * `isPartial: false` — the box starts **collapsed** so the
 *     chat focuses on the answer. The user can click to expand
 *     and read the reasoning.
 *
 * The user can manually toggle at any time; the auto-expand /
 * auto-collapse only sets the initial state.
 */
import { useState } from "react";

export function ThinkingBlock({ thinking, isPartial = false }) {
  // Initial state mirrors the partial flag. The parent's `key`
  // prop forces a re-mount on the partial↔final transition so
  // this initializer runs again with the new value.
  const [isExpanded, setIsExpanded] = useState(isPartial);

  if (!thinking) return null;

  return (
    <div className="mt-3 border border-amber-200 rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        aria-expanded={isExpanded}
        className="w-full flex items-center justify-between px-3 py-2 bg-amber-50 hover:bg-amber-100 transition-colors text-sm"
      >
        <div className="flex items-center gap-2 text-amber-700">
          <svg
            className="w-4 h-4"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="Thinking icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
            />
          </svg>
          <span className="font-medium">Thinking</span>
          {isPartial && (
            <span
              className="inline-flex gap-1 ml-1"
              role="status"
              aria-label="Streaming thinking"
            >
              <span
                className="w-1.5 h-1.5 bg-amber-500 rounded-full animate-bounce"
                style={{ animationDelay: "0ms" }}
                aria-hidden="true"
              />
              <span
                className="w-1.5 h-1.5 bg-amber-500 rounded-full animate-bounce"
                style={{ animationDelay: "150ms" }}
                aria-hidden="true"
              />
              <span
                className="w-1.5 h-1.5 bg-amber-500 rounded-full animate-bounce"
                style={{ animationDelay: "300ms" }}
                aria-hidden="true"
              />
            </span>
          )}
        </div>
        <svg
          className={`w-4 h-4 text-amber-600 transition-transform ${
            isExpanded ? "rotate-180" : ""
          }`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-label={isExpanded ? "Collapse" : "Expand"}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M19 9l-7 7-7-7"
          />
        </svg>
      </button>
      {isExpanded && (
        <div className="px-3 py-2 bg-amber-50/50 text-sm text-amber-800 whitespace-pre-wrap break-words">
          {thinking}
        </div>
      )}
    </div>
  );
}
