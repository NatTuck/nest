/**
 * StatusBanner component — shows a top-of-page banner for
 * connection states: connecting (spinner), error (with Retry),
 * or disconnected (with Reconnect). Returns `null` for the
 * connected state — the chat input is then the primary UI.
 */
export function StatusBanner({ status, error, onRetry }) {
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

  return null;
}
