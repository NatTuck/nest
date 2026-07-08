/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Uses URL as source of truth for which agent to display.
 * Cache is independent of what's shown - we show the cached data
 * for the agent in the URL, if any exists.
 */

import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { useStore } from "../store";
import {
  joinAgent,
  leaveAgent,
  sendMessage,
  stopMessage,
  retryCompaction,
} from "../channels";
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
import { CopyButton } from "../components/CopyButton";
import { useScrollToBottom } from "../hooks/useScrollToBottom";
import { stripModePrefix } from "../utils/stripModePrefix.js";
import { messageToMarkdown } from "../utils/formatMessage.js";
import { messageText, streamingText } from "../utils/messageText.js";

/**
 * Chat Page component
 */
export function ChatPage() {
  const { name } = useParams();
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
  const cache = agentsCache[name];

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
  // Pass the full `usage` object to the chip — the chip reads
  // `context_input_tokens` (server-derived) for the current
  // context fill, and the cumulative `total_*` fields for the
  // session cost estimate. See `TokenUsageChip.jsx` for the
  // full field-by-field layout.
  const usage = cache?.usage ?? null;

  // History navigation list for ChatInput's Ctrl/Cmd+Up / Down support.
  // Pulls user messages from both the active session and the archived
  // (post-compaction) history, orders them most-recent-first, and
  // collapses consecutive duplicates so repeated presses of Up don't
  // dwell on the same message.
  //
  // The persisted user message content has a `[mode: <name>]\n` prefix
  // (see ChatPipeline.build_user_messages/3). We strip it here so the
  // recovered prompt is the user-visible text, not the LLM-facing wire
  // form.
  const history = useMemo(() => {
    const archived = (cache?.history ?? [])
      .filter((m) => m.role === "user" && typeof m.content === "string")
      .map((m) => ({
        content: stripModePrefix(m.content, m.mode ?? ""),
        mode: m.mode ?? null,
      }));
    const active = (cache?.messages ?? [])
      .filter((m) => m.role === "user" && typeof m.content === "string")
      .map((m) => ({
        content: stripModePrefix(m.content, m.mode ?? ""),
        mode: m.mode ?? null,
      }));
    const ordered = [...archived, ...active];
    const deduped = [];
    for (const entry of ordered) {
      const last = deduped[deduped.length - 1];
      if (!last || last.content !== entry.content) deduped.push(entry);
    }
    return deduped.reverse();
  }, [cache?.messages, cache?.history]);

  // Keep the dropdown in sync with the agent's current mode.
  //
  // The agent's `state.mode` is the source of truth and is updated
  // each time a chat is sent ("sticky mode"). The server emits the
  // new mode on every `chat:status` push (specifically the one that
  // transitions to `idle` and unlocks the input), which the
  // channels.js handler writes to `cache.currentMode`. This effect
  // mirrors that into the local `currentMode` React state so the
  // dropdown reflects what the server actually has.
  //
  // On first mount (before any chat:status has arrived),
  // `cache.currentMode` is null and we fall back to `defaultMode`.
  useEffect(() => {
    const next = cache?.currentMode ?? defaultMode;
    if (next) {
      setCurrentMode(next);
    }
  }, [cache?.currentMode, defaultMode]);

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
    name,
    partial ? streamingText(partial) : messages,
  );

  // Join agent channel on mount/name change
  useEffect(() => {
    if (!name) return;

    // Idempotent: joinAgent handles already-connected case
    joinAgent(name);

    return () => {
      leaveAgent(name);
    };
  }, [name]);

  const handleSendMessage = () => {
    if (!inputValue.trim() || isAgentBusy) {
      return;
    }

    const content = inputValue.trim();
    const mode = currentMode ?? defaultMode;
    setInputValue("");
    setSendError(null);
    // The mode for the next message is set by the chat:status: idle
    // broadcast (which updates `cache.currentMode`); the effect
    // above mirrors that into the local `currentMode` state. No
    // client-side reset here.

    sendMessage(name, content, mode, (err) => {
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
    stopMessage(name, (err) => {
      // The push failed (e.g. agent not in the registry).
      // Clear the optimistic flag so the UI doesn't get stuck
      // in the "Stopping..." state.
      setStopping(false);
      setSendError(err.message || "Failed to stop");
    });
  };

  const handleRetry = () => {
    setSendError(null);
    joinAgent(name);
  };

  // Re-run the compactor after a `:compaction_failed` banner.
  // The server validates the agent is in `:compaction_failed`
  // status; otherwise the push is rejected with an error reason
  // that we surface via `setSendError` for visibility.
  const handleRetryCompaction = () => {
    retryCompaction(name, (err) => {
      setSendError(err?.reason || "Failed to retry compaction");
    });
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
              {name}
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
            <TokenUsageChip usage={usage} contextLimit={contextLimit} />
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

      {/* Status banner — `agentState` carries the agent's GenServer
          state (including `:compacting` / `:compaction_failed`),
          distinct from the connection-level `status`. The banner
          handles both axes. */}
      <StatusBanner
        status={agentState ?? status}
        error={cache?.error}
        onRetry={handleRetry}
        onRetryCompaction={handleRetryCompaction}
        compactionError={cache?.compactionError}
      />

      {/* Notification banner */}
      <NotificationBanner
        notification={cache?.notification}
        onClose={() => useStore.getState().clearNotification(name)}
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
                          : name}
                  </span>
                  {message.role === "user" && message.mode && (
                    <span className="text-xs px-2 py-0.5 rounded-full bg-blue-100 text-blue-700 font-medium">
                      mode: {message.mode}
                    </span>
                  )}
                  {message.isPartial && (
                    <span className="text-xs text-gray-400">(typing...)</span>
                  )}
                  <span className="ml-auto">
                    <CopyButton
                      text={messageToMarkdown(message)}
                      label="Copy message"
                    />
                  </span>
                </div>
                {/* Thinking is rendered BEFORE the reply and
                    stays in place across the partial → final
                    transition. The box always starts expanded
                    (the user wanted the reasoning to remain
                    visible after the turn completes) and the
                    user can collapse it manually — no `key`
                    re-mount is needed since the box's state
                    doesn't need to change on finalization. See
                    `assets/js/components/ThinkingBlock.jsx`
                    for the full rationale. */}
                <ThinkingBlock
                  thinking={thinkingFor(message)}
                  isPartial={message.isPartial ?? false}
                  hasVisibleContent={hasVisibleContent(message)}
                />
                {message.role === "system" ? (
                  <SystemMessageContent
                    parts={message.parts}
                    isPartial={message.isPartial ?? false}
                  />
                ) : (
                  <MessageContent
                    parts={
                      message.role === "user"
                        ? [
                            {
                              kind: "text",
                              text: stripModePrefix(
                                messageText(message),
                                message.mode,
                              ),
                            },
                          ]
                        : message.parts
                    }
                    isPartial={message.isPartial ?? false}
                    className="text-gray-800"
                  />
                )}
                <ToolCalls toolCalls={message.toolCalls} />
                <ToolResults toolResults={message.toolResults} />
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
          // Hide the input entirely while the agent is in a
          // frozen state. The StatusBanner shows the relevant
          // banner: a spinner for `:compacting`, a Retry button
          // for `:compaction_failed`, or the context-too-small
          // message for `:context_overflow` (no Retry — switching
          // to a larger model is the only way forward).
          frozen={
            agentState === "compacting" ||
            agentState === "compaction_failed" ||
            agentState === "context_overflow"
          }
          placeholder={
            status === "connected"
              ? "Type a message..."
              : "Connect to send messages..."
          }
          modes={availableModes}
          mode={currentMode ?? defaultMode}
          onModeChange={setCurrentMode}
          history={history}
        />
      </div>
    </div>
  );
}

// Extract the thinking/reasoning text for any message shape.
// The streaming accumulator carries `parts` (the canonical
// `[{kind: "thinking"|"text", text|thinking}]` list). The
// finalized message also carries `parts`. Anthropic-style
// reasoning models emit a single contiguous thinking block
// before the visible text, so the parts list is typically
// `[{thinking}, {text}]` — we concatenate any thinking parts
// (handles the rare case of multiple thinking parts in one
// turn) so the unified `<ThinkingBlock>` has one string to
// render. The legacy `message.thinking` field is consulted
// last (only seen on wire-format messages that pre-date the
// parts cleanup).
function thinkingFor(message) {
  if (!message) return null;

  if (Array.isArray(message.parts)) {
    const thinking = message.parts
      .filter((p) => p && p.kind === "thinking")
      .map((p) => p.thinking || "")
      .join("");

    if (thinking) return thinking;
  }

  return message.thinking || null;
}

// True when the message has visible text below the ThinkingBox.
// Uses the shared `messageText` helper (which reads `parts`
// first, with a `content` fallback for legacy shapes).
function hasVisibleContent(message) {
  return messageText(message).trim().length > 0;
}

const SYSTEM_MESSAGE_MAX_LINES = 20;

// Renders system message content with line-count truncation. If the
// content exceeds SYSTEM_MESSAGE_MAX_LINES, only the first N lines
// are shown with an expand link.
//
// An empty system message (no system prompt was configured for
// this agent) is still rendered — as a dimmed placeholder — so the
// user can see that a system message was sent to the LLM (the
// `AGENTS.md` transparency rule: the UI always includes everything
// that happened). Without this, an agent with no system prompt
// would have no visible representation of position 0 in the
// messages list, and the conversation history would be confusing.
function SystemMessageContent({ parts, isPartial }) {
  const [expanded, setExpanded] = useState(false);

  const text = Array.isArray(parts)
    ? parts
        .filter((p) => p && p.kind === "text")
        .map((p) => p.text || "")
        .join("")
    : "";

  if (!text) {
    return (
      <div className="text-sm italic text-gray-400 border-l-2 border-gray-200 pl-2">
        (empty system message — no system prompt was configured for this agent)
      </div>
    );
  }

  if (isPartial) {
    return (
      <MessageContent
        parts={[{ kind: "text", text }]}
        isPartial
        className="text-gray-800"
      />
    );
  }

  const lines = text.split("\n");
  const showExpand = lines.length > SYSTEM_MESSAGE_MAX_LINES;
  const visibleLines = expanded
    ? lines
    : lines.slice(0, SYSTEM_MESSAGE_MAX_LINES);
  const hiddenCount = lines.length - SYSTEM_MESSAGE_MAX_LINES;

  return (
    <div>
      <MessageContent
        parts={[{ kind: "text", text: visibleLines.join("\n") }]}
        className="text-gray-800"
      />
      {showExpand && (
        <button
          type="button"
          onClick={() => setExpanded(!expanded)}
          className="mt-2 text-sm text-blue-600 hover:text-blue-800 underline"
        >
          {expanded
            ? "Show less"
            : `Expand ${hiddenCount} more line${hiddenCount !== 1 ? "s" : ""}`}
        </button>
      )}
    </div>
  );
}
