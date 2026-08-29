/**
 * The scrollable message area: compaction marker, empty state,
 * `MessagesList` + `StreamingMessage`. Extracted from `ChatPage`.
 */

import { CompactionMarker } from "./CompactionMarker";
import { MessagesList } from "./MessagesList";
import { StreamingMessage } from "./StreamingMessage";

export function ChatMessages({
  messages,
  partial,
  archivedHistory,
  name,
  setScrollContainerEl,
  setMessagesEndEl,
}) {
  const hasActive = messages.length > 0 || partial;
  const marker = archivedHistory.findLast
    ? archivedHistory.findLast((m) => m.role === "compaction")
    : [...archivedHistory].reverse().find((m) => m.role === "compaction");

  return (
    <div
      ref={setScrollContainerEl}
      className="flex-1 overflow-y-auto space-y-4 mb-4 pr-2"
    >
      {hasActive && archivedHistory.length > 0 && (
        <CompactionMarker
          marker={marker}
          history={archivedHistory}
          historyCount={archivedHistory.length}
        />
      )}

      {messages.length === 0 && !partial ? (
        <div className="text-center py-12 text-gray-400">
          <svg
            className="w-16 h-16 mx-auto mb-4 opacity-50"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="Chat icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={1.5}
              d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
            />
          </svg>
          <p className="text-lg font-medium">Start a conversation</p>
          <p className="text-sm mt-1">Send a message to begin chatting</p>
        </div>
      ) : (
        <>
          <MessagesList agentName={name} />
          <StreamingMessage agentName={name} />
        </>
      )}

      <div ref={setMessagesEndEl} />
    </div>
  );
}
