/**
 * ToolCalls component — displays the tool calls in an assistant
 * message. Each tool call shows its name and a truncated JSON
 * preview of its arguments.
 */
import { TruncatedResult } from "./TruncatedResult";
import { sortArgumentsForDisplay } from "../utils/argumentDisplay";

export function ToolCalls({ toolCalls }) {
  if (!toolCalls || toolCalls.length === 0) return null;

  return (
    <div className="mt-3 space-y-2">
      {toolCalls.map((call) => (
        <div
          key={call.id}
          className="bg-purple-50 border border-purple-200 rounded-lg p-3"
        >
          <div className="flex items-center gap-2 text-purple-700 font-medium text-sm">
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
                d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
              />
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
            </svg>
            <span>Using tool: {call.name}</span>
          </div>
          {call.arguments && Object.keys(call.arguments).length > 0 && (
            <TruncatedResult
              content={JSON.stringify(
                sortArgumentsForDisplay(call.arguments),
                null,
                2,
              )}
              className="text-purple-600"
              maxLines={3}
              previewLines={3}
              previewMaxChars={300}
            />
          )}
        </div>
      ))}
    </div>
  );
}
