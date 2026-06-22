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
import { joinAgent, leaveAgent, sendMessage, stopMessage } from "../channels";
import { MessageContent } from "../components/MessageContent";
import { ChatInput } from "../components/ChatInput";
import { TokenUsageChip } from "../components/TokenUsageChip";
import { ToolCalls } from "../components/ToolCalls";
import { ToolResults } from "../components/ToolResults";
import { ThinkingBlock } from "../components/ThinkingBlock";
import { ApiLogsBlock } from "../components/ApiLogsBlock";
import { StatusBanner } from "../components/StatusBanner";
import { NotificationBanner } from "../components/NotificationBanner";
import { CompactionMarker } from "../components/CompactionMarker";
import { useScrollToBottom } from "../hooks/useScrollToBottom";

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
  // Tracks the optimistic "stop in flight" state. Flips to `true`
  // immediately when the user clicks Stop, then back to `false`
  // when the next `chat:status` push arrives (which carries the
  // `idle` status that flips `isAgentBusy` to false). The
  // optimistic flip avoids a brief window where the button
  // reverts to Send before the stop takes effect.
  const [stopping, setStopping] = useState(false);

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
  // `isAgentBusy` is true whenever the agent is doing work that
  // can be interrupted: streaming an LLM response, or executing
  // a tool call between LLM turns. The "busy" state replaces
  // Send with Stop. We deliberately exclude `waitingForResponse`
  // here — that's a transient client-side flag that flips on
  // for a few milliseconds right after `chat:message` push and
  // before the first `chat:status` arrives; showing Stop during
  // that window would flicker the button.
  const isAgentBusy = streaming || executingTools;
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

  // When the agent transitions out of "busy" (the server's
  // `chat:status: idle` push has arrived), clear the optimistic
  // "stopping" flag. The transition is driven by the same
  // `chat:status` event that flips `agentState` to `idle`, so
  // there's no race: the order of state updates within React
  // guarantees `isAgentBusy` becomes false in the same render
  // (or the one after) as `stopping` is reset.
  useEffect(() => {
    if (!isAgentBusy && stopping) {
      setStopping(false);
    }
  }, [isAgentBusy, stopping]);

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
    if (!inputValue.trim() || isAgentBusy) {
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

  // User clicked Stop. Optimistically flip `stopping` to true
  // (the button now shows "Stopping..."), then issue the
  // `chat:stop` push to the channel. The push completes
  // immediately (`{:ok, %{}}`); the actual stop finalization
  // happens asynchronously on the server and arrives as a
  // `chat:status: idle` push, which clears `stopping` via the
  // effect above.
  const handleStopMessage = () => {
    setStopping(true);
    stopMessage(id, (err) => {
      // The push failed (e.g. agent not in the registry).
      // Clear the optimistic flag so the UI doesn't get stuck
      // in the "Stopping..." state.
      setStopping(false);
      setSendError(err.message || "Failed to stop");
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

  // Input is disabled when not connected or when the agent is
  // busy (the user shouldn't be able to type into the textarea
  // while the model is responding or tools are running).
  const isInputDisabled = status !== "connected" || isAgentBusy;

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
            <p className="text-sm text-gray-500 break-all">
              {(() => {
                const name = cache?.model?.name;
                const provider = cache?.model?.provider;
                if (!name) return "[missing]";
                return provider ? `${provider}: ${name}` : name;
              })()}
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
          onStop={handleStopMessage}
          isBusy={isAgentBusy}
          stopping={stopping}
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
