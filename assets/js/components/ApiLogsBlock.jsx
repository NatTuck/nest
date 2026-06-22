/**
 * ApiLogsBlock component — displays the API request/response
 * logs associated with a message. The block is collapsed by
 * default; expanding it shows a JSON-formatted dump of each
 * log entry's payload.
 */
import { useState } from "react";

export function ApiLogsBlock({ apiLogs }) {
  const [isExpanded, setIsExpanded] = useState(false);

  if (!apiLogs || apiLogs.length === 0) return null;

  return (
    <div className="mt-3 border border-indigo-200 rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center justify-between px-3 py-2 bg-indigo-50 hover:bg-indigo-100 transition-colors text-sm"
      >
        <div className="flex items-center gap-2 text-indigo-700">
          <svg
            className="w-4 h-4"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="API log icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
            />
          </svg>
          <span className="font-medium">API Logs ({apiLogs.length})</span>
        </div>
        <svg
          className={`w-4 h-4 text-indigo-600 transition-transform ${isExpanded ? "rotate-180" : ""}`}
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
        <div className="bg-white p-3 space-y-3 max-h-96 overflow-y-auto">
          {apiLogs.map((log) => (
            <div
              key={log.timestamp}
              className="border border-gray-200 rounded-lg overflow-hidden"
            >
              <div className="px-3 py-2 bg-gray-50 border-b border-gray-200 text-xs text-gray-500">
                {new Date(log.timestamp).toLocaleTimeString()}
              </div>
              <pre className="p-3 text-xs text-gray-700 whitespace-pre-wrap break-words overflow-x-hidden bg-gray-50">
                {JSON.stringify(log.payload, null, 2)}
              </pre>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
