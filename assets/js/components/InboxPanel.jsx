/**
 * InboxPanel — the messages queued for an agent while it is busy, plus
 * the replies it still owes.
 *
 * Four kinds share the queue:
 *
 *   - `kind: "agent"` — another agent's own words: an `agents-send` from
 *     a peer, or a child agent's completed turn.
 *   - `kind: "user"` — a chat message a human sent mid-turn.
 *   - `kind: "query"` — an `agents-query` from a peer, which obliges
 *     this agent to answer (see the debt row below).
 *   - `kind: "notice"` — the runtime speaking for itself: a give-up on an
 *     unanswered query, or a child that failed, was stopped or produced
 *     nothing. The runtime generated it, so it must never be framed as a
 *     peer's words.
 *
 * An idle recipient processes a message immediately, so the queue is
 * populated only while the agent is busy. The count is always shown; the
 * full contents expand on click for transparency.
 *
 * The reply debt (`owedReplies`) is shown outside that collapsible body:
 * while the debt stands the agent does not settle to idle, so the debt is
 * the reason it is still working and must not be hidden behind a toggle.
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
 *
 * A `query` entry is a peer asking this agent for an answer. Its label
 * says only that it *is* a query: the obligation it will create is
 * stated by the debt row, which is the one place that knows it — the
 * debt is set at delivery, so a still-queued query has none yet and the
 * two must not disagree.
 *
 * A `notice` entry comes from the runtime, not from a peer, so it is
 * never rendered as `From agent X`; when the entry names the agent it
 * concerns, it says so.
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
  if (message.kind === "query") {
    return from
      ? `Query from agent ${from}`
      : "Query from an unidentified agent";
  }
  if (message.kind === "notice") {
    return from ? `Runtime notice (about agent ${from})` : "Runtime notice";
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

/**
 * The peers this agent owes a reply to (`agents-query` senders that have
 * not been answered yet). The debt is set when a query is *delivered*,
 * so a query still sitting in the queue above is not listed here yet.
 *
 * The wire contract always carries the list — `[]` when nothing is owed
 * — so anything that is not an array means the server did not send it.
 * That is surfaced explicitly rather than rendered as "nothing owed",
 * which is the one reading the missing data does not support.
 */
function OwedReplies({ owed }) {
  if (!Array.isArray(owed)) {
    return (
      <div
        data-testid="inbox-owed-replies-missing"
        className="border-b border-red-200 bg-red-50 px-3 py-2 text-xs font-semibold text-red-700"
      >
        Owes a reply to: (missing from the status payload)
      </div>
    );
  }
  if (owed.length === 0) return null;
  return (
    <div
      data-testid="inbox-owed-replies"
      className="border-b border-amber-200 bg-amber-50 px-3 py-2 text-xs font-medium text-amber-800"
    >
      Owes a reply to {owed.join(", ")}
    </div>
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
  const owed = useStore(
    (state) => state.agentsCache[name]?.owedReplies ?? null,
  );
  // Whether the agent has a cache entry at all. The join runs in an
  // effect after the first commit, so on a first visit to an agent page
  // there is no entry yet: that is "nothing to report", not a payload
  // that omitted the debt. Only an entry that *exists* without the field
  // is a contract violation.
  const hasEntry = useStore((state) => state.agentsCache[name] !== undefined);
  const [open, setOpen] = useState(false);
  // The entry's `from` for a human message is the sender's username, so
  // the panel needs the current user to tell "you" from another human.
  const currentUsername = useStore(
    (state) => state.currentUser?.username ?? null,
  );

  if (!hasEntry) return null;

  const total = Math.max(count, inbox.length);
  const hasQueue = total > 0;
  // A missing `owedReplies` is rendered too, so the panel cannot vanish
  // while the reply debt is unknown.
  const hasDebt = !Array.isArray(owed) || owed.length > 0;

  if (!hasQueue && !hasDebt) return null;

  const handleToggle = () => {
    const next = !open;
    setOpen(next);
    // The full list may lag the count if a `chat:inbox` broadcast was
    // missed; refetch on open so the viewer is never silently empty.
    if (next && onFetch) onFetch();
  };

  return (
    <div className="mb-3 overflow-hidden rounded-lg border border-sky-200 bg-sky-50">
      <OwedReplies owed={owed} />

      {hasQueue && (
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
      )}

      {open && hasQueue && (
        <ul className="max-h-64 space-y-2 overflow-y-auto border-t border-sky-200 px-3 py-2">
          {inbox.map((message) => (
            <li
              // The wire shape carries no id, so the key is the whole
              // entry. It stays stable across re-renders (the list is
              // replaced wholesale by `chat:inbox`) and distinguishes
              // the sources.
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
