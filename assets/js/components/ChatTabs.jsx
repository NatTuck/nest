/**
 * Tab bar for the chat page: the conversation, the agent's shell jobs (every
 * `shell-cmd` call while it runs, plus any background job it started), and —
 * below `lg` only — the pane.
 *
 * The jobs panel used to render inline above the message list, where a handful
 * of jobs pushed the conversation off screen; as a tab it no longer competes
 * with the message list for height.
 *
 * The pane's third tab is the phone's control for the pane (#169's toggle is the
 * desktop's, in the trailing slot). Both exist in the markup and a breakpoint
 * decides which one a reader gets: the tab is `lg:hidden`, the trailing slot is
 * `hidden lg:block`. There is no JS viewport check anywhere — a window's layout
 * is Tailwind's business, and the two controls can never be on screen at once.
 *
 * The tab is only offered once a `pane:state` frame has arrived (`hasPane`):
 * there is nothing to show before that, and a tab that opens an empty view is a
 * control over nothing — the same rule that keeps `PaneToggle` absent until
 * then.
 *
 * Extracted from `ChatPage` to keep that file under the source-line cap.
 */

export const CHAT_TAB = "chat";
export const JOBS_TAB = "jobs";
export const PANE_TAB = "pane";

function tabClass(active) {
  return [
    // `py-3` below `lg` is a 44px target for a thumb; `lg:py-1.5` is the height
    // the bar has always had on a desktop.
    "inline-flex items-center justify-center rounded-t-md border-b-2 px-3 py-3 text-sm font-medium transition-colors duration-150 lg:py-1.5",
    active
      ? "border-blue-600 text-blue-700"
      : "border-transparent text-gray-500 hover:bg-gray-50 hover:text-gray-700",
  ].join(" ");
}

export function ChatTabs({
  active,
  onSelect,
  jobCount = 0,
  trailing = null,
  hasPane = false,
}) {
  const tabs = [
    { id: CHAT_TAB, label: "Chat" },
    { id: JOBS_TAB, label: `Shell jobs (${jobCount})` },
  ];

  if (hasPane) {
    tabs.push({ id: PANE_TAB, label: "Pane", phoneOnly: true });
  }

  return (
    <div
      role="tablist"
      aria-label="Chat views"
      className="mb-4 flex items-center gap-1 border-b border-gray-200"
    >
      {tabs.map(({ id, label, phoneOnly }) => (
        <button
          key={id}
          type="button"
          role="tab"
          aria-selected={active === id}
          onClick={() => onSelect(id)}
          className={[tabClass(active === id), phoneOnly && "lg:hidden"]
            .filter(Boolean)
            .join(" ")}
        >
          {label}
        </button>
      ))}
      {/* The pane's toggle (#169): the tab bar's right-hand end is the one band
          with nothing under it, and it is chrome the conversation cannot scroll
          away. A closed pane must not cost the conversation a column, and an
          overlay in the chat's corner would cover the header's live status.
          Desktop only: below `lg` the pane's tab above is the control, and two
          controls for one view on a 375px bar would be one too many. */}
      {trailing && <div className="ml-auto hidden lg:block">{trailing}</div>}
    </div>
  );
}
