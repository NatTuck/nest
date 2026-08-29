/**
 * The "waiting / generating / executing tools" typing indicator shown
 * beneath the message area. Extracted from `ChatPage`.
 */

import { StreamingDots } from "./StreamingDots";

export function ChatTypingIndicator({
  waitingForResponse,
  streaming,
  executingTools,
}) {
  if (!waitingForResponse && !streaming && !executingTools) {
    return null;
  }

  return (
    <div className="flex items-center gap-2 py-2 px-4 mb-2">
      <span className="text-sm text-gray-500">
        {streaming
          ? "Generating response"
          : executingTools
            ? "Executing tools"
            : "Waiting for response"}
      </span>
      <div className="flex items-center gap-1">
        <StreamingDots colorClass="bg-blue-500" ariaLabel="Working" />
      </div>
    </div>
  );
}
