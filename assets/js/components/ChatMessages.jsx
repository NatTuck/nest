/**
 * The scrollable message area: compaction marker, empty state,
 * `MessagesList` + `StreamingMessage`. Extracted from `ChatPage`.
 *
 * The archive is never shipped whole, so the compaction marker comes
 * from the cache (the lazily-fetched `lastCompactionMarker`) rather
 * than from a history list: `archivedHistory` is empty until the user
 * expands the card, and only holds the pages loaded so far.
 */

import { CompactionMarker } from "./CompactionMarker";
import { MessagesList } from "./MessagesList";
import { StreamingMessage } from "./StreamingMessage";

export function ChatMessages({
  messages,
  partial,
  archivedHistory,
  lastCompactionIndex,
  lastCompactionMarker,
  historyError,
  onLoadHistory,
  onLoadOlder,
  name,
  loading,
  setScrollContainerEl,
  setMessagesEndEl,
}) {
  const hasActive = messages.length > 0 || partial;
  const hasArchive =
    typeof lastCompactionIndex === "number" && lastCompactionIndex >= 0;

  return (
    <div
      ref={setScrollContainerEl}
      className="flex-1 overflow-y-auto space-y-4 mb-4 pr-2"
    >
      {hasActive && hasArchive && (
        <CompactionMarker
          marker={lastCompactionMarker}
          history={archivedHistory}
          historyCount={lastCompactionIndex + 1}
          historyError={historyError}
          onLoadHistory={onLoadHistory}
          onLoadOlder={onLoadOlder}
        />
      )}

      {!hasActive && loading ? (
        <ConversationLoading />
      ) : !hasActive ? (
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

/**
 * The transcript's loading state: a conversation is on its way, but no row has
 * arrived yet.
 *
 * Deliberately distinct from the empty state. For a cold agent the window spans
 * the channel join, the agent process starting, and every sync batch of the
 * drain, and "Start a conversation" is a claim about the agent's history —
 * making that claim during the window is what reads as a click that did
 * nothing.
 *
 * Whether the cache is still filling is the caller's call, not this component's.
 * It cannot be read off an empty `messages`: the active list does not always
 * contain a system row (an agent whose whole sequence is archived and whose
 * archive has no system row reports 0), so an empty list is not by itself
 * evidence of an empty conversation. Hence `loading` as a prop, computed by
 * `ChatPage` from the server's row count.
 */
function ConversationLoading() {
  return (
    <div
      className="flex flex-col items-center gap-3 py-12"
      role="status"
      aria-label="Loading conversation"
    >
      <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-blue-600" />
      <p className="text-sm text-gray-500">Loading conversation...</p>
    </div>
  );
}
