/**
 * ThinkingBlock component — displays the model's thinking /
 * reasoning content in a collapsible block. The block is
 * collapsed by default to keep the chat focused on the response.
 */
import { useState } from "react";

export function ThinkingBlock({ thinking }) {
  // Hook must be called before any early returns.
  const [isExpanded, setIsExpanded] = useState(false);

  if (!thinking) return null;

  return (
    <div className="mt-3 border border-amber-200 rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
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
        </div>
        <svg
          className={`w-4 h-4 text-amber-600 transition-transform ${
            isExpanded ? "rotate-180" : ""
          }`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-label="Expand icon"
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
