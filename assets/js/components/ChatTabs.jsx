/**
 * Tab bar for the chat page: the conversation and the agent's
 * background shell jobs are separate views. The jobs panel used to
 * render inline above the message list, where a handful of jobs pushed
 * the conversation off screen; as a tab it no longer competes with the
 * message list for height.
 *
 * Extracted from `ChatPage` to keep that file under the source-line cap.
 */

export const CHAT_TAB = "chat";
export const JOBS_TAB = "jobs";

function tabClass(active) {
  return [
    "rounded-t-md border-b-2 px-3 py-1.5 text-sm font-medium transition-colors duration-150",
    active
      ? "border-blue-600 text-blue-700"
      : "border-transparent text-gray-500 hover:bg-gray-50 hover:text-gray-700",
  ].join(" ");
}

export function ChatTabs({ active, onSelect, jobCount = 0 }) {
  const tabs = [
    { id: CHAT_TAB, label: "Chat" },
    { id: JOBS_TAB, label: `Background jobs (${jobCount})` },
  ];

  return (
    <div
      role="tablist"
      aria-label="Chat views"
      className="mb-4 flex items-center gap-1 border-b border-gray-200"
    >
      {tabs.map(({ id, label }) => (
        <button
          key={id}
          type="button"
          role="tab"
          aria-selected={active === id}
          onClick={() => onSelect(id)}
          className={tabClass(active === id)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
