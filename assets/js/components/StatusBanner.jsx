/**
 * StatusBanner component — shows a top-of-page banner for
 * connection states (connecting, error, disconnected) and for
 * the compaction failure/loop states (compaction_failed with
 * a Retry button, compaction_loop_detected with an OK button,
 * context_overflow with no action button).
 *
 * The in-progress `:compacting` state does NOT render a banner
 * here — the compactor's `compaction.ex` records the suffix +
 * a synthetic assistant message into the agent's message list
 * even on failure, so the user can see the compaction attempt
 * (and the failure) in the chat pane itself, no special
 * in-progress state required. Only the error/loop states
 * (which need an explicit user action — Retry or OK) warrant a
 * banner.
 *
 * Returns `null` for the connected/idle state — the chat input
 * is then the primary UI.
 */
export function StatusBanner({
  status,
  error,
  onRetry,
  onRetryCompaction,
  onCompactionLoopOk,
  compactionError,
  compactionLoop,
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

  if (status === "compaction_loop_detected") {
    // Distinct from compaction_failed: this is the loop-breaker
    // tripping (consecutive compactions without progress). The
    // recovery is "OK" — the user acknowledges and types a fresh
    // message; the next compaction cycle gets a clean counter.
    return (
      <div className="bg-yellow-100 border-l-4 border-yellow-500 p-4 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-yellow-800 font-medium">
              Compaction isn't reducing context
            </p>
            <p className="text-yellow-700 text-sm">
              {compactionLoop ||
                "Compaction is no longer reducing the conversation."}
            </p>
          </div>
          <button
            type="button"
            onClick={onCompactionLoopOk}
            className="px-4 py-2 bg-yellow-600 text-white rounded-lg hover:bg-yellow-700 transition-colors text-sm"
          >
            OK
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
