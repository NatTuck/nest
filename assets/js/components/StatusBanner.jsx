/**
 * StatusBanner component — shows a top-of-page banner for
 * connection states: connecting (spinner), error (with Retry),
 * disconnected (with Reconnect), or agent-level compaction
 * states: compacting (spinner, no button), compaction_failed
 * (with Retry button that calls onRetryCompaction).
 *
 * `context_overflow` is distinct from compaction_failed: the
 * model is fundamentally too small for the system prompt and
 * retrying will not help. The banner therefore omits the Retry
 * button and instructs the user to switch models or clear the
 * conversation. The `error` prop carries the actual numbers
 * (system prompt size, context limit) from the server.
 *
 * Returns `null` for the connected/idle state — the chat input
 * is then the primary UI.
 */
export function StatusBanner({
  status,
  error,
  onRetry,
  onRetryCompaction,
  compactionError,
}) {
  if (status === "connecting") {
    return (
      <div className="bg-blue-100 border-l-4 border-blue-500 p-4 mb-4">
        <div className="flex items-center">
          <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-blue-600 mr-3" />
          <p className="text-blue-700">Connecting to agent...</p>
        </div>
      </div>
    );
  }

  if (status === "error") {
    return (
      <div className="bg-red-100 border-l-4 border-red-500 p-4 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-red-700 font-medium">Connection failed</p>
            <p className="text-red-600 text-sm">{error || "Unknown error"}</p>
          </div>
          <button
            type="button"
            onClick={onRetry}
            className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors text-sm"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  if (status === "disconnected") {
    return (
      <div className="bg-yellow-100 border-l-4 border-yellow-500 p-4 mb-4">
        <div className="flex items-center justify-between">
          <p className="text-yellow-700">Disconnected. Connection lost.</p>
          <button
            type="button"
            onClick={onRetry}
            className="px-4 py-2 bg-yellow-600 text-white rounded-lg hover:bg-yellow-700 transition-colors text-sm"
          >
            Reconnect
          </button>
        </div>
      </div>
    );
  }

  if (status === "compacting") {
    return (
      <div className="bg-blue-100 border-l-4 border-blue-500 p-4 mb-4">
        <div className="flex items-center">
          <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-blue-600 mr-3" />
          <p className="text-blue-700">Compacting conversation...</p>
        </div>
      </div>
    );
  }

  if (status === "compaction_failed") {
    return (
      <div className="bg-red-100 border-l-4 border-red-500 p-4 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-red-700 font-medium">Compaction failed</p>
            <p className="text-red-600 text-sm">
              {compactionError || "Click Retry to try again."}
            </p>
          </div>
          <button
            type="button"
            onClick={onRetryCompaction}
            className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors text-sm"
          >
            Retry compaction
          </button>
        </div>
      </div>
    );
  }

  if (status === "context_overflow") {
    return (
      <div className="bg-red-100 border-l-4 border-red-500 p-4 mb-4">
        <div className="flex items-start">
          <div>
            <p className="text-red-700 font-medium">Context too small</p>
            <p className="text-red-600 text-sm whitespace-pre-line">
              {error ||
                "The model's context window cannot fit even the system prompt. Use a model with a larger context window, or start a new conversation."}
            </p>
            <p className="text-red-600 text-sm mt-2">
              Switching to a model with a larger context window is the only way
              forward — retrying will not help.
            </p>
          </div>
        </div>
      </div>
    );
  }

  return null;
}
