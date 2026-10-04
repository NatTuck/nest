/**
 * InboxPanel — the async agent-to-agent messages queued for an agent
 * (`agents-send`). An idle recipient processes a message immediately, so
 * this panel is populated only while the agent is busy. The count is
 * always shown; the full contents expand on click for transparency.
 */

import { useState } from "react";
import { useStore } from "../store";

const EMPTY_INBOX = [];

export function InboxPanel({ name, onFetch }) {
  const inbox = useStore(
    (state) => state.agentsCache[name]?.inbox ?? EMPTY_INBOX,
  );
  const count = useStore(
    (state) =>
      state.agentsCache[name]?.pendingMessageCount ?? EMPTY_INBOX.length,
  );
  const [open, setOpen] = useState(false);

  if (inbox.length === 0 && !count) return null;

  const total = Math.max(count, inbox.length);

  const handleToggle = () => {
    const next = !open;
    setOpen(next);
    // The full list may lag the count if a `chat:inbox` broadcast was
    // missed; refetch on open so the viewer is never silently empty.
    if (next && onFetch) onFetch();
  };

  return (
    <div className="mb-3 rounded-lg border border-sky-200 bg-sky-50">
      <button
        type="button"
        onClick={handleToggle}
        className="flex w-full items-center justify-between px-3 py-2 text-left"
        aria-expanded={open}
      >
        <span className="text-sm font-medium text-sky-800">
          {total} message{total === 1 ? "" : "s"} waiting from other agents
        </span>
        <span className="text-xs font-medium text-sky-600">
          {open ? "Hide" : "Show"}
        </span>
      </button>

      {open && (
        <ul className="max-h-64 space-y-2 overflow-y-auto border-t border-sky-200 px-3 py-2">
          {inbox.map((message) => (
            <li
              key={`${message.from}-${message.timestamp}-${message.content}`}
              className="rounded bg-white/70 p-2"
            >
              <div className="mb-1 text-xs font-semibold text-sky-700">
                From {message.from}
              </div>
              <div className="whitespace-pre-wrap break-words text-sm text-gray-800">
                {message.content}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
