/**
 * ChatChrome — the chat page's chrome: the agent header, the banner stack, and
 * the conversation/jobs tab bar.
 *
 * Why it is its own module: the page is at its file-size cap, and this block is
 * presentational — every value and every handler is passed in, so nothing here
 * reads the store, the channel, or the page's state.
 *
 * It renders a **fragment** of two siblings on purpose. The scrollable chrome
 * region and the tab bar are separate children of the page's column (issue #86:
 * the tab bar is chrome the conversation must not squeeze, and it is what the
 * chrome region shrinks against), so a wrapper element here would put a node
 * between them and break the column's layout contract.
 */

import { ChatHeader } from "./ChatHeader";
import { ChatTabs } from "./ChatTabs";
import { ModelMissingBanner } from "./ModelMissingBanner";
import { NeedsRepairBanner } from "./NeedsRepairBanner";
import { NotificationBanner } from "./NotificationBanner";
import { SendErrorBanner } from "./SendErrorBanner";
import { SpacePausedBanner } from "./SpacePausedBanner";
import { StatusBanner } from "./StatusBanner";

export function ChatChrome({
  // The header's own fields.
  name,
  vocation,
  model,
  agentState,
  changeModelError,
  parentName,
  depth,
  spaceSlug,
  usage,
  descendantUsage,
  totalUsage,
  contextLimit,
  status,
  streaming,
  statusLabel,
  // What the banners report.
  error,
  compactionError,
  compactionLoop,
  notification,
  sendError,
  sequenceViolations,
  repairCommand,
  reloadError,
  spaceId,
  spaceName,
  // The tab bar.
  tab,
  jobCount,
  // The pane's toggle, rendered in the tab bar's trailing slot (#169).
  paneToggle,
  // What the user can do from the chrome.
  onSelectTab,
  onModelPickerOpen,
  onRetry,
  onDismiss,
  onRetryCompaction,
  onCompactionLoopOk,
  onReload,
  onClearNotification,
}) {
  return (
    <>
      <div className="min-h-0 overflow-y-auto">
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
          onModelPickerOpen={onModelPickerOpen}
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
          status={
            status === "error" && error ? "error" : (agentState ?? status)
          }
          error={error}
          onRetry={onRetry}
          onDismiss={onDismiss}
          onRetryCompaction={onRetryCompaction}
          onCompactionLoopOk={onCompactionLoopOk}
          compactionError={compactionError}
          compactionLoop={compactionLoop}
        />

        {/* Repair banner — only shown when the agent's persisted
          model no longer resolves to a runtime provider
          (status ":model_missing"). Per the recovery flow,
          the user picks a replacement model from here; the
          channel layer blocks all `chat:message` traffic
          while in this state, so this banner is the only way
          forward. The picker's selection closes the picker
          and pushes `"change_model"` over the lobby channel. */}
        {agentState === "model_missing" && (
          <ModelMissingBanner model={model} onChooseModel={onModelPickerOpen} />
        )}

        {/* Repair banner — the persisted active sequence failed wire
          validation at load (status ":needs_repair"). Chat is blocked
          until the operator runs the offline repair command and
          reloads the agent. */}
        {agentState === "needs_repair" && (
          <NeedsRepairBanner
            violations={sequenceViolations}
            repairCommand={repairCommand}
            onReload={onReload}
            error={reloadError}
          />
        )}

        {/* The space's environment is being edited: work is held, and the user
          has to see that rather than an agent that looks stuck. */}
        <SpacePausedBanner spaceId={spaceId} spaceName={spaceName} />

        {/* Notification banner */}
        <NotificationBanner
          notification={notification}
          onClose={onClearNotification}
        />

        {/* Send error */}
        <SendErrorBanner message={sendError} />
      </div>

      {/* The conversation and the agent's background shell jobs are
        separate views: the jobs panel used to render inline above the
        message list, where a handful of jobs pushed the conversation
        off screen. `shrink-0`: the tab bar is chrome the conversation
        must not squeeze, and it is what the chrome region above shrinks
        against. */}
      <div className="shrink-0">
        <ChatTabs
          active={tab}
          onSelect={onSelectTab}
          jobCount={jobCount}
          trailing={paneToggle}
        />
      </div>
    </>
  );
}
