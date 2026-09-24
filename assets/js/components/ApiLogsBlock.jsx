/**
 * ApiLogsBlock — displays the API logs associated with a message.
 *
 * Assistant messages carry their response log inline (stored on the
 * message, persisted, and sent in the default payload). User and tool
 * messages never carry a stored request log — theirs is synthetic and
 * fetched on demand when the user expands the widget (a
 * `chat:api-logs` channel push, cached locally).
 *
 * Expected data is never silently dropped: if a response log is
 * expected but missing, or a request-log fetch fails/returns nothing,
 * the widget renders a visible error indicator instead of disappearing.
 */
import { useState } from "react";
import { CopyButton } from "./CopyButton";
import { formatApiLogsAsJson } from "../utils/formatMessage.js";
import { agentChannels } from "../channels/state";

const REQUEST_LOG_ROLES = new Set(["user", "tool"]);

function ApiLogsIcon({ className = "w-4 h-4" }) {
  return (
    <svg
      className={className}
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
  );
}

function WarningIcon() {
  return (
    <svg
      className="w-4 h-4 flex-shrink-0"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-label="Warning"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M12 9v2m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"
      />
    </svg>
  );
}

function Spinner() {
  return (
    <svg
      className="w-4 h-4 animate-spin text-indigo-600"
      fill="none"
      viewBox="0 0 24 24"
      aria-label="Loading"
    >
      <circle
        className="opacity-25"
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        strokeWidth="4"
      />
      <path
        className="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
      />
    </svg>
  );
}

function ErrorIndicator({ message, onRetry }) {
  return (
    <div className="mt-3 flex items-center gap-2 px-3 py-2 text-xs text-amber-800 border border-amber-300 bg-amber-50 rounded-lg">
      <WarningIcon />
      <span className="flex-1">{message}</span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="font-medium underline hover:no-underline"
        >
          Retry
        </button>
      )}
    </div>
  );
}

function LoadingBlock() {
  return (
    <div className="mt-3 border border-indigo-200 rounded-lg overflow-hidden">
      <div className="w-full flex items-center gap-2 px-3 py-2 bg-indigo-50 text-sm text-indigo-700">
        <ApiLogsIcon />
        <span className="font-medium">API Logs</span>
        <Spinner />
      </div>
    </div>
  );
}

function LoadButton({ onClick }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="mt-3 flex items-center gap-2 px-3 py-2 text-xs text-indigo-500 hover:text-indigo-700 border border-dashed border-indigo-200 rounded-lg hover:border-indigo-300"
      aria-label="Load API logs"
    >
      <ApiLogsIcon />
      API Logs
    </button>
  );
}

function LogsBlock({ logs, isExpanded, onToggle }) {
  return (
    <div className="mt-3 border border-indigo-200 rounded-lg overflow-hidden">
      <div className="w-full flex items-center justify-between px-3 py-2 bg-indigo-50 text-sm">
        <button
          type="button"
          onClick={onToggle}
          aria-label="Toggle API logs"
          className="flex items-center gap-2 text-indigo-700 hover:text-indigo-900"
        >
          <ApiLogsIcon />
          <span className="font-medium">{`API Logs (${logs.length})`}</span>
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
        <CopyButton
          getText={() => formatApiLogsAsJson(logs)}
          label="Copy API logs"
        />
      </div>
      {isExpanded && (
        <div className="bg-white p-3 space-y-3 max-h-96 overflow-y-auto">
          {logs.map((log) => (
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

export function ApiLogsBlock({
  apiLogs,
  agentName,
  index,
  messageRole,
  expectsResponseLog,
}) {
  const [isExpanded, setIsExpanded] = useState(false);
  const [loadedApiLogs, setLoadedApiLogs] = useState(null);
  const [isLoading, setIsLoading] = useState(false);
  const [loadError, setLoadError] = useState(null);

  const displayLogs = loadedApiLogs ?? apiLogs;
  const hasLogs = Array.isArray(displayLogs) && displayLogs.length > 0;
  const canFetchRequestLog =
    REQUEST_LOG_ROLES.has(messageRole) && Boolean(agentName) && index != null;
  const responseLogExpected =
    expectsResponseLog !== undefined
      ? expectsResponseLog
      : messageRole === "assistant";

  const fetchRequestLog = () => {
    const channel = agentChannels.get(agentName);
    if (!channel) {
      setLoadError("channel unavailable");
      return;
    }

    setLoadError(null);
    setIsLoading(true);

    channel
      .push("chat:api-logs", { index })
      .receive("ok", (resp) => {
        setIsLoading(false);
        setLoadedApiLogs(Array.isArray(resp?.apiLogs) ? resp.apiLogs : []);
        setIsExpanded(true);
      })
      .receive("error", (resp) => {
        setIsLoading(false);
        setLoadError(resp?.reason || "request failed");
      });
  };

  if (hasLogs) {
    return (
      <LogsBlock
        logs={displayLogs}
        isExpanded={isExpanded}
        onToggle={() => setIsExpanded(!isExpanded)}
      />
    );
  }

  if (isLoading) return <LoadingBlock />;

  if (Array.isArray(loadedApiLogs) && loadedApiLogs.length === 0) {
    return (
      <ErrorIndicator
        message="API request log unavailable"
        onRetry={canFetchRequestLog ? fetchRequestLog : null}
      />
    );
  }

  if (loadError) {
    return (
      <ErrorIndicator
        message={`API logs unavailable (${loadError})`}
        onRetry={canFetchRequestLog ? fetchRequestLog : null}
      />
    );
  }

  if (canFetchRequestLog) return <LoadButton onClick={fetchRequestLog} />;

  if (responseLogExpected) {
    return <ErrorIndicator message="API response log missing — not recorded" />;
  }

  // A request-log role whose log can't be fetched (e.g. an archived
  // message with no live agent channel): still surface the gap rather
  // than silently hiding the widget.
  if (REQUEST_LOG_ROLES.has(messageRole)) {
    return <ErrorIndicator message="API request log unavailable" />;
  }

  return null;
}
