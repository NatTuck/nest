/**
 * ThinkingBlock — collapsible box for the model's thinking /
 * reasoning content. This is the one and only component that
 * renders thinking/reasoning text in the chat UI; the visible
 * reply is rendered by `<MessageContent>`. See `ChatPage.jsx`
 * and `CollapsedHistory.jsx` for callers.
 *
 * The box is always visible (the "Thinking" header) and
 * always starts expanded when there's thinking content. The
 * user can click the header to collapse it. We never auto-
 * collapse on the partial → final transition — the user
 * explicitly asked for the reasoning to remain visible after
 * the turn completes, so the chat doesn't have a flicker
 * between an expanded "thinking" state and a collapsed
 * "thinking" state as the assistant message finalizes.
 *
 * The `isPartial` prop drives the streaming indicator (the
 * bouncing dots) in the header; it does NOT change the
 * expanded/collapsed state.
 */
import { useState } from "react";

export function ThinkingBlock({
  thinking,
  isPartial = false,
  hasVisibleContent = true,
}) {
  // The box always starts expanded. The user can collapse it
  // manually with the header button; that state survives the
  // partial → final transition (no parent `key` re-mount).
  //
  // `isPartial` and `hasVisibleContent` remain in the API for
  // a future policy change but are not used for the initial
  // state. `isPartial` still drives the streaming dots in the
  // header.
  const [isExpanded, setIsExpanded] = useState(true);

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
