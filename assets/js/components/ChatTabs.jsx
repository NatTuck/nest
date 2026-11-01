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
 * `hidden lg:block`. That is Tailwind's decision and no JS reads a width to make
 * it, so the two controls can never be on screen at once. (The UI's one
 * media-query listener, `useOnDesktop`, retires the tab's *selection* when a
 * window widens — that is stranded state, not layout.)
 *
 * The tab is only offered once a `pane:state` frame has arrived (`hasPane`):
 * there is nothing to show before that, and a tab that opens an empty view is a
 * control over nothing — the same rule that keeps `PaneToggle` absent until
 * then.
 *
 * It also carries the **waiting signal** (`waitingCount`): the amber dot and the
 * number of questions still wanting an answer, which is the whole notification
 * the desktop's `PaneToggle` gives. Without it the phone's tab would look the
 * same whether nothing or five questions were waiting — a question arriving
 * would be invisible until the reader opened the tab, which is the one thing the
 * phone would do worse than the desktop for the same state. The count reaches
 * the tab's accessible name too, so it is not a colour-only signal.
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
  waitingCount = 0,
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
      {tabs.map(({ id, label, phoneOnly }) => {
        // Only the pane has anything to report, and only while it is the phone's
        // tab. Every other tab keeps its bare text node, so the desktop bar is
        // the same markup it has always been.
        const waiting = phoneOnly ? waitingCount : 0;

        return (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={active === id}
            // The badge is a number and a colour; the name has to carry both.
            aria-label={
              waiting > 0
                ? `${label}, ${waiting} question${waiting === 1 ? "" : "s"} waiting`
                : undefined
            }
            onClick={() => onSelect(id)}
            className={[tabClass(active === id), phoneOnly && "lg:hidden"]
              .filter(Boolean)
              .join(" ")}
          >
            {waiting > 0 ? (
              <span className="flex items-center gap-1">
                {label}
                <span
                  data-testid="pane-tab-waiting"
                  className="flex items-center gap-1 rounded-full bg-amber-100 px-1.5 py-0.5 text-[11px] font-semibold text-amber-900"
                >
                  <span
                    className="h-1.5 w-1.5 rounded-full bg-amber-500"
                    aria-hidden="true"
                  />
                  {waiting}
                </span>
              </span>
            ) : (
              label
            )}
          </button>
        );
      })}
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
