/**
 * Chat agent header: name, model chip (opens the edit dialog), the "back to
 * parent" link, and the token-usage chip + status.
 *
 * ## Two shapes, one component
 *
 * Below `lg` the header is **the phone's top bar**: its name, the view it is
 * showing, the status dot, and a chevron that opens everything else — the
 * vocation, the model chip, the token readout, the status label, the parent
 * link and the view switcher. It renders *into* `PhoneTopBar`'s slot through
 * `PhoneBarSlotContext` (a portal), so the app spends one 44px row on chrome
 * instead of the two it used to: the bar's own, and this one under it.
 *
 * From `lg` up it is the header it has always been, always expanded, in the
 * column above the conversation.
 *
 * The dot is centred on the name rather than top-aligned with it, which is what
 * makes a one-line bar read as one line; the name is truncated rather than
 * wrapped, because a bar that wraps is two rows again — and the disclosure
 * carries the whole name, so nothing is only reachable by hovering.
 *
 * No JS reads a width for any of this: the split is which tree the node is
 * rendered into, and the breakpoints are `lg:hidden` / `hidden lg:block`.
 */

import { useState } from "react";
import { createPortal } from "react-dom";
import { Link } from "react-router-dom";
import { ChevronDown } from "./ChevronDown";
import { TokenUsageChip } from "./TokenUsageChip";
import { usePhoneBarSlot } from "./PhoneBarSlot";
import { PhoneTabs } from "./ChatTabs";

export function ChatHeader({
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
  // The pane's waiting questions. The badge on the chevron is the phone's only
  // signal that something wants an answer: it used to ride the pane's tab, and
  // the tab is behind this chevron now, so a signal there would be one the
  // reader has to open a disclosure to see.
  waitingCount = 0,
  // The view this page is showing, when it is not the conversation — the chip
  // beside the name. A phone has no tab bar to say "you are in Shell jobs", and
  // the composer disappears on those views, so without this the page silently
  // becomes a different page.
  viewName = null,
  // The view showing, and the views there are to show. The header renders the
  // phone's group itself rather than taking it as a node, because picking a view
  // has to close the disclosure it was picked from: the panel is a menu, and a
  // menu left open over the view it opened is in the way of that view.
  tab = null,
  jobCount = 0,
  hasPane = false,
  onSelectTab = null,
  onModelPickerOpen,
  getStatusLabel,
}) {
  // Closed on every mount, and per agent: the disclosure is a phone convenience,
  // not a preference, so it does not belong in the store.
  const [detailsOpen, setDetailsOpen] = useState(false);
  const toggleDetails = () => setDetailsOpen((open) => !open);
  const pickView = (id) => {
    setDetailsOpen(false);
    if (onSelectTab) onSelectTab(id);
  };

  const slot = usePhoneBarSlot();

  const dotClass = [
    "w-3 h-3 rounded-full",
    status === "connected" ? "bg-green-500" : "bg-gray-300",
    streaming ? "animate-pulse" : "",
  ].join(" ");

  const modelLabel = (() => {
    const modelName = model?.name;
    const provider = model?.provider;
    if (!modelName) return "[missing]";
    return provider ? `${provider}: ${modelName}` : modelName;
  })();

  const modelChip = (
    <button
      type="button"
      onClick={onModelPickerOpen}
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
      <span className="font-mono text-xs truncate">{modelLabel}</span>
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
  );

  // The phone's bar row: name, the view it is showing, the dot, the disclosure.
  const phoneRow = (
    <div
      data-testid="phone-header"
      className="flex h-11 min-w-0 items-center gap-2"
    >
      <h1 className="min-w-0 truncate text-lg font-bold text-gray-900">
        {name}
      </h1>
      {viewName && (
        <span
          data-testid="active-view-chip"
          className="shrink-0 rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600"
        >
          {viewName}
        </span>
      )}
      <div className="ml-auto flex shrink-0 items-center">
        {/* The dot is the one piece of the status row that stays on the line, so
            it carries the label for a screen reader — a colour alone is not a
            status. */}
        <span role="img" aria-label={getStatusLabel()} className={dotClass} />
        <button
          type="button"
          onClick={toggleDetails}
          aria-expanded={detailsOpen}
          // The badge is a number and a colour; the name has to carry both,
          // which is the rule the pane's tab followed before the signal moved
          // here.
          aria-label={
            waitingCount > 0
              ? `Agent details, ${waitingCount} question${waitingCount === 1 ? "" : "s"} waiting`
              : "Agent details"
          }
          className="relative inline-flex h-11 w-11 items-center justify-center rounded-lg text-gray-500 transition-colors hover:bg-gray-100 active:bg-gray-200"
        >
          <ChevronDown rotated={detailsOpen} />
          {waitingCount > 0 && (
            <span
              data-testid="phone-waiting-badge"
              className="absolute top-0.5 right-0.5 flex items-center gap-0.5 rounded-full bg-amber-100 px-1 text-[10px] leading-4 font-semibold text-amber-900"
            >
              <span
                className="h-1.5 w-1.5 rounded-full bg-amber-500"
                aria-hidden="true"
              />
              {waitingCount}
            </span>
          )}
        </button>
      </div>
    </div>
  );

  // Everything the chevron opens. Bounded in `dvh` and scrollable: a short phone
  // must not lose the conversation to its own details panel.
  const phonePanel = detailsOpen && (
    <div
      data-testid="phone-panel"
      className="max-h-[60dvh] space-y-1 overflow-y-auto border-t border-gray-200 pb-2 pt-1"
    >
      {/* The whole name: the row truncates it, so this is where it stays
          readable — no hover, no title. */}
      <p className="text-sm font-medium break-all text-gray-900">{name}</p>
      {vocation?.name && (
        <p className="text-sm text-gray-500">{vocation.name}</p>
      )}
      <p className="text-sm text-gray-500 break-all">
        {modelChip}
        {changeModelError && (
          <span className="ml-2 text-xs text-red-600">{changeModelError}</span>
        )}
      </p>
      {parentName && (
        <p className="text-xs text-gray-500">
          ↑{" "}
          <Link
            to={`/space/${encodeURIComponent(spaceSlug)}/agent/${encodeURIComponent(parentName)}`}
            className="text-blue-600 hover:underline"
          >
            back to {parentName}
          </Link>
          {depth > 0 && (
            <span className="text-gray-400 ml-2">(depth {depth})</span>
          )}
        </p>
      )}
      <TokenUsageChip
        usage={usage}
        descendantUsage={descendantUsage}
        totalUsage={totalUsage}
        contextLimit={contextLimit}
      />
      <div className="flex items-center gap-2">
        <div className={dotClass} />
        <span className="text-sm text-gray-400">{getStatusLabel()}</span>
      </div>
      <div className="pt-1">
        <PhoneTabs
          active={tab}
          onSelect={pickView}
          jobCount={jobCount}
          hasPane={hasPane}
        />
      </div>
    </div>
  );

  const phone = (
    <>
      {phoneRow}
      {phonePanel}
    </>
  );

  // From `lg` up: the header the desktop has always had, always expanded.
  const desktop = (
    <div
      data-testid="desktop-header"
      className="border-b border-gray-200 pb-4 mb-4"
    >
      <div className="flex flex-col gap-2 lg:flex-row lg:items-end lg:justify-between lg:gap-4">
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-gray-900">
            {name}
            {vocation?.name && (
              <span className="text-gray-500 font-normal">
                {" "}
                ({vocation.name})
              </span>
            )}
          </h1>
          <p className="text-sm text-gray-500 break-all">
            {modelChip}
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
                to={`/space/${encodeURIComponent(spaceSlug)}/agent/${encodeURIComponent(parentName)}`}
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
        <div className="flex min-w-0 flex-col items-end gap-2">
          <TokenUsageChip
            usage={usage}
            descendantUsage={descendantUsage}
            totalUsage={totalUsage}
            contextLimit={contextLimit}
          />
          <div className="flex items-center gap-2">
            <div className={dotClass} />
            <span className="text-sm text-gray-400">{getStatusLabel()}</span>
          </div>
        </div>
      </div>
    </div>
  );

  return (
    <>
      {/* Into the top bar when there is one (the app's `Layout`), inline when
          there is not (a component test, or any page without the bar). */}
      {slot ? (
        createPortal(phone, slot)
      ) : (
        <div className="border-b border-gray-200 pb-2 mb-2 lg:hidden">
          {phone}
        </div>
      )}
      <div className="hidden lg:block">{desktop}</div>
    </>
  );
}
