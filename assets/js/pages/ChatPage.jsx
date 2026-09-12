/**
 * Chat Page - Interface for chatting with an agent.
 *
 * Uses URL as source of truth for which agent to display.
 * Cache is independent of what's shown - we show the cached data
 * for the agent in the URL, if any exists.
 */

import { useEffect, useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { useShallow } from "zustand/shallow";
import { useStore } from "../store";
import {
  joinAgent,
  leaveAgent,
  sendMessage,
  stopMessage,
  retryCompaction,
  compactionLoopOk,
  editAgent,
} from "../channels";
import { StatusBanner } from "../components/StatusBanner";
import { NotificationBanner } from "../components/NotificationBanner";
import { ChatHeader } from "../components/ChatHeader";
import { ChatComposer } from "../components/ChatComposer";
import { ChatMessages } from "../components/ChatMessages";
import { ChatTypingIndicator } from "../components/ChatTypingIndicator";
import { ChatLoading } from "../components/ChatLoading";
import { AgentEditModal } from "../components/AgentEditModal";
import { SendErrorBanner } from "../components/SendErrorBanner";
import { ModelMissingBanner } from "../components/ModelMissingBanner";
import { useScrollToBottom } from "../hooks/useScrollToBottom";
import { buildChatHistory } from "../utils/chatHistory.js";
import { describeEditError, getStatusLabel } from "../utils/chatErrors.js";

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
  const { spaceSlug, name } = useParams();
  const spaces = useStore((state) => state.spaces) ?? [];
  // Resolve the current space id from the route's slug. The
  // sidebar and channel joins all key off the integer space id.
  const spaceId = spaces.find((s) => s.slug === spaceSlug)?.id ?? null;
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
    workspace_path,
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
        workspace_path: cache?.workspace_path ?? null,
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
  const compacting = agentState === "compacting";
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
  // the agent that spawned this one via `agents-spawn` (with
  // `clone_context`), or `null` for root agents. Surfaced as
  // a "back to parent" link in the agent header (a child can
  // navigate back to its parent's chat without an extra
  // round-trip).
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
  const history = useMemo(
    () => buildChatHistory(messages, archivedHistory),
    [messages, archivedHistory],
  );

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
  const statusLabel = getStatusLabel(
    status,
    streaming,
    executingTools,
    waitingForResponse,
    compacting,
  );

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

  // Join agent channel on mount/name/space change. The topic
  // is `agent:<space_id>:<name>`, so the space must be resolved
  // before joining.
  useEffect(() => {
    if (!name || !spaceId) return;

    // Idempotent: joinAgent handles already-connected case
    joinAgent(name, spaceId);

    return () => {
      leaveAgent(name);
    };
  }, [name, spaceId]);

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
    joinAgent(name, spaceId);
  };

  // Push a new model to the server. Reset any previous error
  // before firing so a typo'd provider doesn't lock the user
  // out of retrying from a clean slate. The server's
  // `agent:updated` broadcast (lobby) and `chat:status`
  // (per-agent) both flow through
  // `applyAgentModelUpdate` so the cache and `agents` list
  // reconcile themselves.
  const handleSaveAgentEdits = (draft) => {
    setChangeModelError(null);
    setModelPickerOpen(false);

    editAgent(
      name,
      spaceId,
      draft.model,
      draft.workspace_path,
      undefined,
      (err) => {
        setChangeModelError(describeEditError(err?.reason));
      },
    );
  };

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
    return <ChatLoading />;
  }

  // Input is disabled when not connected or when the agent is
  // busy (the user shouldn't be able to type into the textarea
  // while the model is responding or tools are running).
  const isInputDisabled = status !== "connected" || isAgentBusy;

  return (
    <div className="flex flex-col h-full max-w-6xl mx-auto">
      {/* Header */}
      <ChatHeader
        name={name}
        vocation={vocation}
        model={model}
        agentState={agentState}
        changeModelError={changeModelError}
        parentName={parentName}
        depth={depth}
        spaceSlug={spaceSlug}
        usage={usage}
        descendantUsage={descendantUsage}
        totalUsage={totalUsage}
        contextLimit={contextLimit}
        status={status}
        streaming={streaming}
        onModelPickerOpen={() => setModelPickerOpen(true)}
        getStatusLabel={() => statusLabel}
      />

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
        <ModelMissingBanner
          model={model}
          onChooseModel={() => setModelPickerOpen(true)}
        />
      )}

      {/* Notification banner */}
      <NotificationBanner
        notification={notification}
        onClose={() => useStore.getState().clearNotification(name)}
      />

      {/* Send error */}
      <SendErrorBanner message={sendError} />

      {/* Messages */}
      <ChatMessages
        messages={messages}
        partial={partial}
        archivedHistory={archivedHistory}
        name={name}
        setScrollContainerEl={setScrollContainerEl}
        setMessagesEndEl={setMessagesEndEl}
      />

      {/* Typing indicator - shown when waiting or generating */}
      <ChatTypingIndicator
        waitingForResponse={waitingForResponse}
        streaming={streaming}
        executingTools={executingTools}
      />

      {/* Input area with floating Jump to latest button */}
      <ChatComposer
        inputValue={inputValue}
        onChange={setInputValue}
        onSend={handleSendMessage}
        onStop={handleStopMessage}
        isBusy={isAgentBusy}
        stopping={stopping}
        disabled={isInputDisabled}
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
        hasNewContent={hasNewContent}
        isAtBottom={isAtBottom}
        jumpToBottom={jumpToBottom}
      />

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
      <AgentEditModal
        open={modelPickerOpen}
        onClose={() => setModelPickerOpen(false)}
        onSave={handleSaveAgentEdits}
        model={model}
        workspace_path={workspace_path}
        vocation={vocation}
      />
    </div>
  );
}

// `thinkingFor` and `textPartsFor` (used by the per-message
// `MessageBubble` component) come from `utils/messageParts.js`
// so the same logic is shared with the archived-history pane.
