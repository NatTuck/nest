/**
 * ToolResults component — displays the results of tool calls in
 * a tool message. Each result shows its name, success/error
 * status, arguments, and content.
 */
import { TruncatedResult } from "./TruncatedResult";
import { sortArgumentsForDisplay } from "../utils/argumentDisplay";

export function ToolResults({ toolResults }) {
  if (!toolResults || toolResults.length === 0) return null;

  return (
    <div className="mt-3 space-y-2">
      {toolResults.map((result) => (
        <div
          key={result.tool_call_id}
          className={`border rounded-lg p-3 ${
            result.is_error
              ? "bg-red-50 border-red-200"
              : "bg-green-50 border-green-200"
          }`}
        >
          <div
            className={`flex items-center gap-2 font-medium text-sm ${
              result.is_error ? "text-red-700" : "text-green-700"
            }`}
          >
            {result.is_error ? (
              <svg
                className="w-4 h-4"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Error icon"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            ) : (
              <svg
                className="w-4 h-4"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Success checkmark icon"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M5 13l4 4L19 7"
                />
              </svg>
            )}
            <span>
              {result.is_error ? "Error" : "Success"}: {result.name}
            </span>
          </div>
          {result.arguments && Object.keys(result.arguments).length > 0 && (
            <TruncatedResult
              content={JSON.stringify(
                sortArgumentsForDisplay(result.arguments),
                null,
                2,
              )}
              className="text-purple-600"
            />
          )}
          {result.content && (
            <TruncatedResult
              content={result.content}
              className={result.is_error ? "text-red-600" : "text-green-600"}
            />
          )}
        </div>
      ))}
    </div>
  );
}
