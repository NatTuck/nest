/**
 * InboxPanel — the messages queued for an agent while it is busy.
 *
 * Two sources share the queue: `agents-send` messages from other agents
 * (`kind: "agent"`) and chat messages a human sent mid-turn
 * (`kind: "user"`). An idle recipient processes a message immediately,
 * so this panel is populated only while the agent is busy. The count is
 * always shown; the full contents expand on click for transparency.
 */

import { useState } from "react";
import { useStore } from "../store";

const EMPTY_INBOX = [];

/**
 * Header label for a queued entry. An `agents-send` entry is named by
 * its sender; a human's queued message is labelled by source — "you" when
 * the entry's `from` is the current user, named otherwise, since the
 * panel can be open on an agent other people are talking to. A sender
 * the server did not identify is called out for every kind rather than
 * rendered as a literal `null`/`undefined`.
 */
function senderLabel(message, currentUsername) {
  const from = typeof message.from === "string" ? message.from.trim() : "";

  if (message.kind === "user") {
    if (!from) return "From an unidentified user";
    if (currentUsername && from === currentUsername) return "From you";
    return `From ${from} the user`;
  }
  if (message.kind === "agent") {
    return from ? `From agent ${from}` : "From an unidentified agent";
  }
  return from
    ? `From ${from} (unknown kind: ${message.kind})`
    : `From an unidentified sender (unknown kind: ${message.kind})`;
}

/**
 * The requested conversation mode for a queued human message. A missing
 * mode is shown as an explicit marker rather than nothing, so the panel
 * never silently implies a default.
 */
function ModeLabel({ mode }) {
  if (typeof mode === "string" && mode.length > 0) {
    return (
      <span className="ml-2 rounded bg-sky-100 px-1.5 py-0.5 font-mono text-[11px] text-sky-800">
        Mode: {mode}
      </span>
    );
  }
  return (
    <span className="ml-2 rounded bg-red-100 px-1.5 py-0.5 font-mono text-[11px] font-semibold text-red-700">
      Mode: (missing)
    </span>
  );
}

export function InboxPanel({ name, onFetch }) {
  const inbox = useStore(
    (state) => state.agentsCache[name]?.inbox ?? EMPTY_INBOX,
  );
  const count = useStore(
    (state) =>
      state.agentsCache[name]?.pendingMessageCount ?? EMPTY_INBOX.length,
  );
  const [open, setOpen] = useState(false);
  // The entry's `from` for a human message is the sender's username, so
  // the panel needs the current user to tell "you" from another human.
  const currentUsername = useStore(
    (state) => state.currentUser?.username ?? null,
  );

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
          {total} message{total === 1 ? "" : "s"} waiting to be delivered
        </span>
        <span className="text-xs font-medium text-sky-600">
          {open ? "Hide" : "Show"}
        </span>
      </button>

      {open && (
        <ul className="max-h-64 space-y-2 overflow-y-auto border-t border-sky-200 px-3 py-2">
          {inbox.map((message) => (
            <li
              // The wire shape carries no id, so the key is the whole
              // entry. It stays stable across re-renders (the list is
              // replaced wholesale by `chat:inbox`) and distinguishes
              // the two sources.
              key={`${message.kind}-${message.from}-${message.timestamp}-${message.content}-${message.mode}`}
              className="rounded bg-white/70 p-2"
            >
              <div className="mb-1 text-xs font-semibold text-sky-700">
                {senderLabel(message, currentUsername)}
                {message.kind === "user" && <ModeLabel mode={message.mode} />}
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
