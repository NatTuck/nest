/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Uses URL as source of truth for which agent to display.
 * Cache is independent of what's shown - we show the cached data
 * for the agent in the URL, if any exists.
 */

import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { useStore } from "../store";
import { joinAgent, leaveAgent, sendMessage } from "../channels";
import { MessageContent } from "../components/MessageContent";
import { ChatInput } from "../components/ChatInput";
import { TokenUsageChip } from "../components/TokenUsageChip";
import { TruncatedResult } from "../components/TruncatedResult";
import { CompactionMarker } from "../components/CompactionMarker";
import { useScrollToBottom } from "../hooks/useScrollToBottom";
import { sortArgumentsForDisplay } from "../utils/argumentDisplay";

/**
 * ToolCalls component - displays tool calls in a message
 */
function ToolCalls({ toolCalls }) {
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

/**
 * ToolResults component - displays tool results in a message
 */
function ToolResults({ toolResults }) {
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

/**
 * ThinkingBlock component - displays thinking/reasoning content
 */
function ThinkingBlock({ thinking }) {
  // Hook must be called before any early returns
  const [isExpanded, setIsExpanded] = useState(false);

  if (!thinking) return null;

  return (
    <div className="mt-3 border border-amber-200 rounded-lg overflow-hidden">
      <button
        type="button"
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center justify-between px-3 py-2 bg-amber-50 hover:bg-amber-100 transition-colors text-sm"
      >
        <div className="flex items-center gap-2 text-amber-700">
          <svg
            className="w-4 h-4"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="Thinking icon"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
            />
          </svg>
          <span className="font-medium">Thinking</span>
        </div>
        <svg
          className={`w-4 h-4 text-amber-600 transition-transform ${
            isExpanded ? "rotate-180" : ""
          }`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-label="Expand icon"
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
        <div className="px-3 py-2 bg-amber-50/50 text-sm text-amber-800 whitespace-pre-wrap break-words">
          {thinking}
        </div>
      )}
    </div>
  );
}

/**
 * ApiLogsBlock component - displays API logs associated with a message
 */
function ApiLogsBlock({ apiLogs }) {
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

/**
 * Status banner component
 */
function StatusBanner({ status, error, onRetry }) {
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

/**
 * Notification banner component for system notifications (non-error)
 */
function NotificationBanner({ notification, onClose }) {
  if (!notification) return null;

  return (
    <div className="bg-amber-50 border-l-4 border-amber-400 p-4 mb-4">
      <div className="flex items-start justify-between">
        <div className="flex items-start">
          <svg
            className="h-5 w-5 text-amber-400 mt-0.5 mr-3 flex-shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
          <p className="text-amber-800 text-sm">{notification.message}</p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="ml-4 text-amber-400 hover:text-amber-600 transition-colors flex-shrink-0"
          aria-label="Dismiss notification"
        >
          <svg
            className="h-5 w-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </div>
    </div>
  );
}

/**
 * Chat Page component
 */
export function ChatPage() {
  const { id } = useParams();
  const [scrollContainerEl, setScrollContainerEl] = useState(null);
  const [messagesEndEl, setMessagesEndEl] = useState(null);
  const [inputValue, setInputValue] = useState("");
  const [sendError, setSendError] = useState(null);
  const [currentMode, setCurrentMode] = useState(null);

  // Get agent cache from store
  const agentsCache = useStore((state) => state.agentsCache);
  const cache = agentsCache[id];

  // Is this an unknown agent (never attempted to join)?
  const isUnknown = !cache;

  // Get status, messages, and partial
  const status = cache?.status ?? "disconnected";
  const messages = cache?.messages ?? [];
  const partial = cache?.partial ?? null;
  const waitingForResponse = cache?.waitingForResponse ?? false;
  const agentState = cache?.agentState ?? "idle";
  const streaming = agentState === "streaming";
  const executingTools = agentState === "executing_tools";
  const availableModes = cache?.modes ?? ["chat"];
  const defaultMode = cache?.defaultMode ?? "chat";
  const contextLimit = cache?.contextLimit ?? null;
  // `usage.input_tokens` is overwritten per LLM call (each call's
  // `input_tokens` is the size of the full context for that call),
  // so the most recent value is the current context size.
  const lastInput = cache?.usage?.input_tokens ?? 0;

  // When the agent's default mode arrives (or changes), reset the
  // current mode to match. This ensures the selector always starts
  // at the agent's default for the next message.
  useEffect(() => {
    if (defaultMode && currentMode === null) {
      setCurrentMode(defaultMode);
    }
  }, [defaultMode, currentMode]);

  // Determine status label
  const getStatusLabel = () => {
    if (status !== "connected") return status;
    if (streaming) return "Generating response";
    if (executingTools) return "Executing tools";
    if (waitingForResponse) return "Waiting for response";
    return "Ready";
  };

  const { isAtBottom, hasNewContent, jumpToBottom } = useScrollToBottom(
    scrollContainerEl,
    messagesEndEl,
    id,
    partial?.content ?? messages,
  );

  // Join agent channel on mount/id change
  useEffect(() => {
    if (!id) return;

    // Idempotent: joinAgent handles already-connected case
    joinAgent(id);

    return () => {
      leaveAgent(id);
    };
  }, [id]);

  const handleSendMessage = () => {
    if (!inputValue.trim() || streaming) {
      return;
    }

    const content = inputValue.trim();
    const mode = currentMode ?? defaultMode;
    setInputValue("");
    setSendError(null);
    // Reset to the default mode for the next message.
    setCurrentMode(defaultMode);

    sendMessage(id, content, mode, (err) => {
      setSendError(err.message || "Failed to send message");
    });
  };

  const handleRetry = () => {
    setSendError(null);
    joinAgent(id);
  };

  // Show initial loading state while we attempt first join
  if (isUnknown) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="flex flex-col items-center gap-4">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600" />
          <p className="text-gray-600">Loading agent...</p>
        </div>
      </div>
    );
  }

  // Combine messages with partial for display
  const displayMessages = [...messages];
  if (partial) {
    displayMessages.push({ ...partial, isPartial: true });
  }

  // Input is disabled when not connected or streaming
  const isInputDisabled = status !== "connected" || streaming;

  return (
    <div className="flex flex-col h-full max-w-6xl mx-auto">
      {/* Header */}
      <div className="border-b border-gray-200 pb-4 mb-4">
        <div className="flex items-end justify-between gap-4">
          <div className="min-w-0">
            <h1 className="text-2xl font-bold text-gray-900">
              {id}
              {cache?.vocation?.name && (
                <span className="text-gray-500 font-normal">
                  ({cache.vocation.name})
                </span>
              )}
            </h1>
            <p className="text-sm text-gray-500">
              {cache?.model?.name || "\u00A0"}
            </p>
          </div>
          <div className="flex flex-col items-end gap-2">
            <TokenUsageChip lastInput={lastInput} contextLimit={contextLimit} />
            <div className="flex items-center gap-2">
              <div
                className={`
                  w-3 h-3 rounded-full
                  ${status === "connected" ? "bg-green-500" : "bg-gray-300"}
                  ${streaming ? "animate-pulse" : ""}
                `}
              />
              <span className="text-sm text-gray-400">{getStatusLabel()}</span>
            </div>
          </div>
        </div>
      </div>

      {/* Status banner */}
      <StatusBanner
        status={status}
        error={cache?.error}
        onRetry={handleRetry}
      />

      {/* Notification banner */}
      <NotificationBanner
        notification={cache?.notification}
        onClose={() => useStore.getState().clearNotification(id)}
      />

      {/* Send error */}
      {sendError && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
          <p className="text-red-700 text-sm">{sendError}</p>
        </div>
      )}

      {/* Messages */}
      <div
        ref={setScrollContainerEl}
        className="flex-1 overflow-y-auto space-y-4 mb-4 pr-2"
      >
        {/* Compaction marker — only render when there are archived
            messages (history) AND active messages to display. The
            marker sits above the active messages, indicating the
            boundary between the archived (history) and visible
            (messages) conversation. */}
        {displayMessages.length > 0 && cache?.history?.length > 0 && (
          <CompactionMarker
            marker={
              cache.history.findLast
                ? cache.history.findLast((m) => m.role === "compaction")
                : [...cache.history]
                    .reverse()
                    .find((m) => m.role === "compaction")
            }
            history={cache.history}
          />
        )}

        {displayMessages.length === 0 ? (
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
          displayMessages.map((message) => (
            <div
              key={message.index}
              className={`
                flex gap-4 p-4 rounded-xl
                ${
                  message.role === "user"
                    ? "bg-blue-50 ml-12"
                    : message.role === "system"
                      ? "bg-amber-50 border border-amber-200 mx-8"
                      : message.role === "tool"
                        ? "bg-green-50 border border-green-200 mx-8"
                        : "bg-gray-50 mr-12"
                }
              `}
            >
              {/* Avatar */}
              <div
                className={`
                  w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0
                  ${
                    message.role === "user"
                      ? "bg-blue-600 text-white"
                      : message.role === "system"
                        ? "bg-amber-500 text-white"
                        : message.role === "tool"
                          ? "bg-green-500 text-white"
                          : "bg-gray-600 text-white"
                  }
                `}
              >
                {message.role === "user"
                  ? "U"
                  : message.role === "system"
                    ? "S"
                    : message.role === "tool"
                      ? "T"
                      : "AI"}
              </div>

              {/* Message content */}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-1">
                  <span className="font-semibold text-sm text-gray-700">
                    {message.role === "user"
                      ? "You"
                      : message.role === "system"
                        ? "System"
                        : message.role === "tool"
                          ? "Tool Result"
                          : id}
                  </span>
                  {message.role === "user" && message.mode && (
                    <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 text-blue-700 font-medium">
                      mode: {message.mode}
                    </span>
                  )}
                  {message.isPartial && (
                    <span className="text-xs text-gray-400">(typing...)</span>
                  )}
                </div>
                <MessageContent
                  content={message.content}
                  segments={message.segments}
                  isPartial={message.isPartial ?? false}
                  className="text-gray-800"
                />
                <ToolCalls toolCalls={message.toolCalls} />
                <ToolResults toolResults={message.toolResults} />
                <ThinkingBlock thinking={message.thinking} />
                <ApiLogsBlock apiLogs={message.apiLogs} />
                {message.isPartial && (
                  <div className="flex items-center gap-1 mt-2">
                    <span
                      className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                      style={{ animationDelay: "0ms" }}
                    />
                    <span
                      className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                      style={{ animationDelay: "150ms" }}
                    />
                    <span
                      className="w-2 h-2 bg-gray-400 rounded-full animate-bounce"
                      style={{ animationDelay: "300ms" }}
                    />
                  </div>
                )}
              </div>
            </div>
          ))
        )}

        <div ref={setMessagesEndEl} />
      </div>

      {/* Typing indicator - shown when waiting or generating */}
      {(waitingForResponse || streaming || executingTools) && (
        <div className="flex items-center gap-2 py-2 px-4 mb-2">
          <span className="text-sm text-gray-500">
            {streaming
              ? "Generating response"
              : executingTools
                ? "Executing tools"
                : "Waiting for response"}
          </span>
          <div className="flex items-center gap-1">
            <span
              className="w-1.5 h-1.5 bg-blue-500 rounded-full animate-bounce"
              style={{ animationDelay: "0ms" }}
            />
            <span
              className="w-1.5 h-1.5 bg-blue-500 rounded-full animate-bounce"
              style={{ animationDelay: "150ms" }}
            />
            <span
              className="w-1.5 h-1.5 bg-blue-500 rounded-full animate-bounce"
              style={{ animationDelay: "300ms" }}
            />
          </div>
        </div>
      )}

      {/* Input area with floating Jump to latest button above it.
          Positioning the button here (in the column's coordinate space, not
          inside the scroll container) keeps it visible regardless of which
          ancestor is the actual scroll region. */}
      <div className="relative">
        {hasNewContent && !isAtBottom && (
          <button
            type="button"
            onClick={jumpToBottom}
            aria-label="Jump to latest messages"
            className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 z-10 px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-full shadow-lg hover:bg-indigo-700 transition-all duration-200 flex items-center gap-1.5"
          >
            <svg
              className="w-4 h-4"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M19 14l-7 7m0 0l-7-7m7 7V3"
              />
            </svg>
            Jump to latest
          </button>
        )}

        <ChatInput
          value={inputValue}
          onChange={setInputValue}
          onSend={handleSendMessage}
          disabled={isInputDisabled}
          placeholder={
            status === "connected"
              ? "Type a message..."
              : "Connect to send messages..."
          }
          modes={availableModes}
          mode={currentMode ?? defaultMode}
          onModeChange={setCurrentMode}
        />
      </div>
    </div>
  );
}
