/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Uses URL as source of truth for which agent to display.
 * Cache is independent of what's shown - we show the cached data
 * for the agent in the URL, if any exists.
 */

import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useShallow } from "zustand/shallow";
import { useStore } from "../store";
import {
  joinAgent,
  leaveAgent,
  sendMessage,
  stopMessage,
  retryCompaction,
  compactionLoopOk,
  changeAgentModel,
} from "../channels";
import { ChatInput } from "../components/ChatInput";
import { TokenUsageChip } from "../components/TokenUsageChip";
import { StatusBanner } from "../components/StatusBanner";
import { NotificationBanner } from "../components/NotificationBanner";
import { CompactionMarker } from "../components/CompactionMarker";
import { StreamingDots } from "../components/StreamingDots";
import { MessagesList } from "../components/MessagesList";
import { StreamingMessage } from "../components/StreamingMessage";
import { AgentModelPicker } from "../components/AgentModelPicker";
import { useScrollToBottom } from "../hooks/useScrollToBottom";
import { stripModePrefix } from "../utils/stripModePrefix.js";

// Stable empty fallbacks so selector return values are
// reference-stable across renders when the underlying slice
// is missing. Otherwise `?? []` would yield a fresh `[]`
// literal each call and trip zustand's `Object.is` check.
const EMPTY_MESSAGES = [];
const EMPTY_HISTORY = [];
const EMPTY_MODES = ["chat"];

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
  // Backing state for the model picker modal. Open the
  // picker either from the header chip (always available)
  // or from the prominent :model_missing banner (the
  // recovery flow). Both paths funnel through the same
  // `handleChangeModel` callback to keep the wire push
  // uniform.
  const [modelPickerOpen, setModelPickerOpen] = useState(false);
  const [changeModelError, setChangeModelError] = useState(null);
  // Tracks the optimistic "stop in flight" state. Flips to `true`
  // immediately when the user clicks Stop, then back to `false`
  // when the next `chat:status` push arrives (which carries the
  // `idle` status that flips `isAgentBusy` to false). The
  // optimistic flip avoids a brief window where the button
  // reverts to Send before the stop takes effect.
  const [stopping, setStopping] = useState(false);

  // Get agent cache from store. The bundle below contains
  // the "header/footer" fields ChatPage renders directly
  // (status, agentState, usage, etc.). These change rarely
  // — only on init, status transitions, token-usage updates,
  // and notifications. Streaming deltas update `partial`,
  // `streaming`, and `waitingForResponse` (NOT in this
  // bundle), so they don't re-trigger ChatPage.
  //
  // `useShallow` does a shallow `Object.is` on each field
  // of the returned object. When the agent's `cache` is
  // replaced (every store update), the selector runs again
  // and returns a new object literal — but every field is
  // either a stable primitive (string, number, boolean) or
  // a reference-stable object (the usage object is replaced
  // only when the server broadcasts a new one), so the
  // shallow comparison short-circuits.
  const {
    status,
    agentState,
    availableModes,
    defaultMode,
    contextLimit,
    usage,
    descendantUsage,
    totalUsage,
    parentName,
    depth,
    model,
    vocation,
    currentMode: currentModeFromCache,
    waitingForResponse,
    error,
    compactionError,
    compactionLoop,
    notification,
  } = useStore(
    useShallow((state) => {
      const cache = state.agentsCache[name];
      return {
        status: cache?.status ?? "disconnected",
        agentState: cache?.agentState ?? "idle",
        availableModes: cache?.modes ?? EMPTY_MODES,
        defaultMode: cache?.defaultMode ?? "chat",
        contextLimit: cache?.contextLimit ?? null,
        usage: cache?.usage ?? null,
        descendantUsage: cache?.descendantUsage ?? null,
        totalUsage: cache?.totalUsage ?? null,
        parentName: cache?.parentName ?? null,
        depth: cache?.depth ?? 0,
        model: cache?.model ?? null,
        vocation: cache?.vocation ?? null,
        currentMode: cache?.currentMode ?? null,
        waitingForResponse: cache?.waitingForResponse ?? false,
        error: cache?.error ?? null,
        compactionError: cache?.compactionError ?? null,
        compactionLoop: cache?.compactionLoop ?? null,
        notification: cache?.notification ?? null,
      };
    }),
  );
  const isUnknown = useStore((state) => !state.agentsCache[name]);

  // Streaming + busy state. `agentState` is from the shallow
  // bundle above; the derived booleans are just string equality.
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

  // Sub-agent identity. `parentName` is the readable id of
  // the agent that spawned this one via `clone_agent`, or
  // `null` for root agents. Surfaced as a "back to parent"
  // link in the agent header (a child can navigate back to
  // its parent's chat without an extra round-trip).
  // `_parentId` is intentionally not used in the render but
  // is kept here so future code that wants the numeric id has
  // it available without re-subscribing.
  const _parentId = useStore(
    (state) => state.agentsCache[name]?.parentId ?? null,
  );

  // Subscriptions for the message list and the in-flight
  // partial. These are reference-stable across deltas
  // (`messages` is replaced only on a `chat:message` append;
  // `partial` is replaced only on `chat:delta` updates), so
  // the granular selectors below do not re-render ChatPage
  // when the other slice changes. The `MessagesList` and
  // `StreamingMessage` components each subscribe to one of
  // these slices directly.
  const messages = useStore(
    (state) => state.agentsCache[name]?.messages ?? EMPTY_MESSAGES,
  );
  const partial = useStore((state) => state.agentsCache[name]?.partial ?? null);
  // `archivedHistory` is the raw cache slice — used by the
  // `CompactionMarker` to render the boundary. Distinct
  // from the `history` variable below, which is the user-
  // facing memoized list of past prompts.
  const archivedHistory = useStore(
    (state) => state.agentsCache[name]?.history ?? EMPTY_HISTORY,
  );

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
    const archived = archivedHistory
      .filter((m) => m.role === "user" && typeof m.content === "string")
      .map((m) => ({
        content: stripModePrefix(m.content, m.mode ?? ""),
        mode: m.mode ?? null,
      }));
    const active = messages
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
  }, [messages, archivedHistory]);

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
  // `currentModeFromCache` is null and we fall back to `defaultMode`.
  useEffect(() => {
    const next = currentModeFromCache ?? defaultMode;
    if (next) {
      setCurrentMode(next);
    }
  }, [currentModeFromCache, defaultMode]);

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

  // The hook only uses the `trigger` value as a dependency
  // for its `useEffect` (it doesn't render the text), so we
  // pass the raw refs (`partial` or `messages`) instead of
  // reconstituting the streaming text on every render. The
  // previous form called `streamingText(partial)` here, which
  // allocated a string of up to ~100KB of the full stream
  // contents on every ChatPage render — multiplied by the
  // delta rate during streaming, that's hundreds of MB/sec of
  // garbage. The reference identity of `partial` is enough:
  // when the store replaces `partial` on `chat:delta`, the
  // hook's `useEffect` re-runs and scrolls if appropriate.
  const { isAtBottom, hasNewContent, jumpToBottom } = useScrollToBottom(
    scrollContainerEl,
    messagesEndEl,
    name,
    partial ?? messages,
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

  // Push a new model to the server. Reset any previous error
  // before firing so a typo'd provider doesn't lock the user
  // out of retrying from a clean slate. The server's
  // `agent:updated` broadcast (lobby) and `chat:status`
  // (per-agent) both flow through
  // `applyAgentModelUpdate` so the cache and `agents` list
  // reconcile themselves.
  const handleChangeModel = (newModel) => {
    setChangeModelError(null);
    setModelPickerOpen(false);

    changeAgentModel(name, newModel, undefined, (err) => {
      setChangeModelError(describeChangeModelError(err?.reason));
    });
  };

  // Translate the server's error-reason string into a
  // user-friendly message. Each branch mirrors a `:reply`
  // reason from `LobbyChannel.handle_in("change_model", …)`.
  function describeChangeModelError(reason) {
    switch (reason) {
      case "agent_busy":
        return "Agent is busy. Wait for the current chat to finish before changing models.";
      case "invalid_model":
        return "That model isn't configured on the server.";
      case "not_found":
        return "Agent not found. Refresh the page and try again.";
      case "invalid_payload":
        return "Couldn't read the model selection. Try again.";
      default:
        return reason
          ? `Failed to change model: ${reason}`
          : "Failed to change model.";
    }
  }

  // Dismiss a chat-task error without re-joining the channel.
  // Useful when the LLM call crashed but the WS channel is
  // still alive (the companion `chat:status: idle` already
  // arrived, so `agentState === "idle"`). Calling
  // `clearAgentError` re-enables the textarea locally; the
  // user can then send a fresh message without a page reload.
  // For genuine channel-join failures (where `agentState` is
  // null), this is a no-op on `status` and the user must Retry.
  const handleDismissError = () => {
    setSendError(null);
    useStore.getState().clearAgentError(name);
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

  // Acknowledge a `:compaction_loop_detected` banner. The
  // server transitions the agent back to `:idle` and clears the
  // loop-breaker counter; the user can then send a new message
  // that may trigger fresh compaction.
  const handleCompactionLoopOk = () => {
    compactionLoopOk(name, (err) => {
      setSendError(err?.reason || "Failed to clear compaction loop");
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
              {vocation?.name && (
                <span className="text-gray-500 font-normal">
                  ({vocation.name})
                </span>
              )}
            </h1>
            <p className="text-sm text-gray-500 break-all">
              <button
                type="button"
                onClick={() => setModelPickerOpen(true)}
                aria-label="Change model"
                className={`
                  inline-flex items-center gap-1
                  px-2 py-0.5 rounded-md
                  transition-colors duration-150
                  hover:bg-gray-100
                  ${
                    agentState === "model_missing"
                      ? "bg-amber-100 text-amber-900 hover:bg-amber-200"
                      : "text-gray-500"
                  }
                `}
              >
                <span className="font-mono text-xs">
                  {(() => {
                    const modelName = model?.name;
                    const provider = model?.provider;
                    if (!modelName) return "[missing]";
                    return provider ? `${provider}: ${modelName}` : modelName;
                  })()}
                </span>
                <svg
                  className="w-3 h-3 opacity-60"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </button>
              {changeModelError && (
                <span className="ml-2 text-xs text-red-600">
                  {changeModelError}
                </span>
              )}
            </p>
            {parentName && (
              <p className="text-xs text-gray-500 mt-1">
                ↑{" "}
                <Link
                  to={`/agent/${encodeURIComponent(parentName)}`}
                  className="text-blue-600 hover:underline"
                >
                  back to {parentName}
                </Link>
                {depth > 0 && (
                  <span className="text-gray-400 ml-2">(depth {depth})</span>
                )}
              </p>
            )}
          </div>
          <div className="flex flex-col items-end gap-2">
            <TokenUsageChip
              usage={usage}
              descendantUsage={descendantUsage}
              totalUsage={totalUsage}
              contextLimit={contextLimit}
            />
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
          handles both axes.

          After a chat-task error the companion `chat:status: idle`
          lands AFTER `chat:error`, so `agentState === "idle"` while
          `cache.status === "error"` is the recoverable case.
          Promote the banner's `status` prop to `"error"` whenever
          `cache.error` is set, so the Retry/Dismiss banner stays
          visible during the idle window instead of silently
          disappearing (a regression that previously required a
          full page reload to recover from). */}
      <StatusBanner
        status={status === "error" && error ? "error" : (agentState ?? status)}
        error={error}
        onRetry={handleRetry}
        onDismiss={handleDismissError}
        onRetryCompaction={handleRetryCompaction}
        onCompactionLoopOk={handleCompactionLoopOk}
        compactionError={compactionError}
        compactionLoop={compactionLoop}
      />

      {/* Repair banner — only shown when the agent's persisted
          model no longer resolves to a runtime provider
          (status ":model_missing"). Per the recovery flow,
          the user picks a replacement model from here; the
          channel layer blocks all `chat:message` traffic
          while in this state, so this banner is the only way
          forward. The picker's selection calls
          `handleChangeModel`, which closes the picker and
          pushes `"change_model"` over the lobby channel. */}
      {agentState === "model_missing" && (
        <div
          role="alert"
          aria-live="polite"
          className="bg-amber-50 border-l-4 border-amber-500 p-4 mb-4"
        >
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <p className="text-amber-900 font-medium">
                Model{" "}
                <span className="font-mono">{model?.name ?? "(unknown)"}</span>{" "}
                is no longer available
              </p>
              <p className="text-amber-800 text-sm mt-1">
                Your conversation history is preserved. Pick a replacement model
                to continue — the agent resumes in{" "}
                <span className="font-mono">idle</span> the moment the new model
                is set.
              </p>
            </div>
            <button
              type="button"
              onClick={() => setModelPickerOpen(true)}
              className="flex-shrink-0 px-4 py-2 rounded-lg font-medium text-amber-900 bg-amber-200 hover:bg-amber-300 active:bg-amber-400 transition-colors"
            >
              Choose replacement model
            </button>
          </div>
        </div>
      )}

      {/* Notification banner */}
      <NotificationBanner
        notification={notification}
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
        {/* Compaction marker — the entry point to the agent's
            archived history. Renders collapsed as a "History"
            header with a "Last compaction: …" sub-line and a
            Show/Hide toggle (the toggle's count is the TOTAL
            archived-message length, not the most recent
            marker's `archivedCount`); when expanded, the full
            sequence renders in original index order. Only
            shown when there are archived messages (history)
            AND active messages to display — both must exist
            for the boundary to be meaningful. */}
        {(messages.length > 0 || partial) && archivedHistory.length > 0 && (
          <CompactionMarker
            marker={
              archivedHistory.findLast
                ? archivedHistory.findLast((m) => m.role === "compaction")
                : [...archivedHistory]
                    .reverse()
                    .find((m) => m.role === "compaction")
            }
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
            <StreamingDots colorClass="bg-blue-500" ariaLabel="Working" />
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
          // banner: a Retry button for `:compaction_failed`, an
          // OK button for `:compaction_loop_detected`, or the
          // context-too-small message for `:context_overflow`
          // (no Retry — switching to a larger model is the only
          // way forward). `:compacting` is intentionally NOT
          // frozen — the compactor records the suffix + a
          // synthetic assistant message in the message list, and
          // the user can watch the chat pane while it runs.
          frozen={
            agentState === "compaction_failed" ||
            agentState === "compaction_loop_detected" ||
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

      {/* Model picker modal — opens from the header chip
          (any state) or the :model_missing banner (repair
          flow). The picker's `onSelect` pushes
          `"change_model"` over the lobby channel. The agent
          broadcasts `agent:updated` back, which
          `applyAgentModelUpdate` propagates into the cache
          and `agents` list. If the new model fails to
          resolve (provider removed, etc.) the server
          replies `agent_busy` or `invalid_model` and we
          surface the message inline below the picker. */}
      <AgentModelPicker
        open={modelPickerOpen}
        onClose={() => setModelPickerOpen(false)}
        onSelect={handleChangeModel}
      />
    </div>
  );
}

// `thinkingFor` and `textPartsFor` (used by the per-message
// `MessageBubble` component) come from `utils/messageParts.js`
// so the same logic is shared with the archived-history pane.
