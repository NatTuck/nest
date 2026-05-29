/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Uses URL as source of truth for which agent to display.
 * Cache is independent of what's shown - we show the cached data
 * for the agent in the URL, if any exists.
 */

import { useEffect, useRef, useState } from "react";
import { useParams } from "react-router-dom";
import { useStore } from "../store";
import { joinAgent, leaveAgent, sendMessage } from "../channels";
import { MessageContent } from "../components/MessageContent";

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
 * Chat Page component
 */
export function ChatPage() {
  const { id } = useParams();
  const messagesEndRef = useRef(null);
  const [inputValue, setInputValue] = useState("");
  const [sendError, setSendError] = useState(null);

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
  const streaming = partial !== null;

  // Determine status label
  const getStatusLabel = () => {
    if (status !== "connected") return status;
    if (streaming) return "Generating response";
    if (waitingForResponse) return "Waiting for response";
    return "Ready";
  };

  // Scroll to bottom when messages change
  // biome-ignore lint/correctness/useExhaustiveDependencies: messages is the dependency we want
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, partial?.content]);

  // Join agent channel on mount/id change
  useEffect(() => {
    if (!id) return;

    // Idempotent: joinAgent handles already-connected case
    joinAgent(id);

    return () => {
      leaveAgent(id);
    };
  }, [id]);

  const handleSendMessage = (e) => {
    e.preventDefault();

    if (!inputValue.trim() || streaming) {
      return;
    }

    const content = inputValue.trim();
    setInputValue("");
    setSendError(null);

    sendMessage(id, content, (err) => {
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
    <div className="flex flex-col h-full max-w-4xl mx-auto">
      {/* Header */}
      <div className="border-b border-gray-200 pb-4 mb-4">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold text-gray-900">{id}</h1>
            <p className="text-sm text-gray-500">{getStatusLabel()}</p>
          </div>
          <div
            className={`
              w-3 h-3 rounded-full
              ${status === "connected" ? "bg-green-500" : "bg-gray-300"}
              ${streaming ? "animate-pulse" : ""}
            `}
          />
        </div>
      </div>

      {/* Status banner */}
      <StatusBanner
        status={status}
        error={cache?.error}
        onRetry={handleRetry}
      />

      {/* Send error */}
      {sendError && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
          <p className="text-red-700 text-sm">{sendError}</p>
        </div>
      )}

      {/* Messages */}
      <div className="flex-1 overflow-y-auto space-y-4 mb-4 pr-2">
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
                        : "bg-gray-600 text-white"
                  }
                `}
              >
                {message.role === "user"
                  ? "U"
                  : message.role === "system"
                    ? "S"
                    : "AI"}
              </div>

              {/* Message content */}
              <div className="flex-1">
                <div className="flex items-center gap-2 mb-1">
                  <span className="font-semibold text-sm text-gray-700">
                    {message.role === "user"
                      ? "You"
                      : message.role === "system"
                        ? "System"
                        : id}
                  </span>
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

        <div ref={messagesEndRef} />
      </div>

      {/* Typing indicator - shown when waiting or generating */}
      {(waitingForResponse || streaming) && (
        <div className="flex items-center gap-2 py-2 px-4 mb-2">
          <span className="text-sm text-gray-500">
            {streaming ? "Generating response" : "Waiting for response"}
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

      {/* Input area */}
      <form
        onSubmit={handleSendMessage}
        className="border-t border-gray-200 pt-4"
      >
        <div className="flex gap-2">
          <input
            type="text"
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            placeholder={
              status === "connected"
                ? "Type a message..."
                : "Connect to send messages..."
            }
            disabled={isInputDisabled}
            className="
              flex-1 px-4 py-3 border border-gray-300 rounded-lg
              focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none
              disabled:bg-gray-100 disabled:cursor-not-allowed
            "
          />
          <button
            type="submit"
            disabled={!inputValue.trim() || isInputDisabled}
            className={`
              px-6 py-3 rounded-lg font-semibold text-white
              transition-all duration-200
              ${
                !inputValue.trim() || isInputDisabled
                  ? "bg-gray-400 cursor-not-allowed"
                  : "bg-blue-600 hover:bg-blue-700 active:bg-blue-800"
              }
            `}
          >
            Send
          </button>
        </div>
      </form>
    </div>
  );
}
