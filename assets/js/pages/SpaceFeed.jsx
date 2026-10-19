/**
 * The space feed — `/space/:slug`, the space's **note log**.
 *
 * One table (`user_notes`) read by the human at one end of each row: the notes
 * they sent and the notes agents (or the runtime) sent them. It is deliberately
 * **not** the transcript — tool calls, tool results, thinking blocks, compaction
 * markers and turns that were not notes are the *agent* page's
 * (`/space/:slug/agent/:name`), and putting them here would make the space page
 * the transcript it deliberately is not (`notes/space-chat.md` § "Two routes, two
 * meanings"). That is why nothing in this page reads `agentsCache`: the feed
 * reads one table, and the agent page answers the other question.
 *
 * What it carries, in reading order:
 *
 *   * the pause banner — a held space is held for every page of it;
 *   * the space's name and blueprint;
 *   * its environment and the dialog that edits it (`SpaceEnvironmentCard`);
 *   * the owed-reply banner — incoming queries not yet answered, advisory only;
 *   * the notes themselves;
 *   * the composer: a recipient picker over the space's agents (root by
 *     default), the mode draft, and the query it sends.
 *
 * The composer sends a **query**, not a plain note, because a query is what
 * obliges the recipient to answer. The reply is the agent's own `agents-send`:
 * picking one assistant message out of a turn and calling it the answer would be
 * a guess.
 *
 * Loading, empty and failed are three different things and the page says which
 * one it is. A read that failed never renders as "nothing has been said".
 */

import { useEffect, useState } from "react";
import { useStore } from "../store";
import { requestSpaceFeed, sendSpaceNote } from "../channels";
import { ChatInput } from "../components/ChatInput";
import { JumpToBottomButton } from "../components/JumpToBottomButton";
import { SendErrorBanner } from "../components/SendErrorBanner";
import { SpaceEnvironmentCard } from "../components/SpaceEnvironmentCard";
import { SpacePausedBanner } from "../components/SpacePausedBanner";
import { useAgentMode } from "../hooks/useAgentMode";
import { useScrollToBottom } from "../hooks/useScrollToBottom";
import { errorText } from "../utils/errorText";
import { formatTimestamp } from "../utils/formatTimestamp";
import { isIncoming, noteDirection, owedAgents } from "../utils/spaceNote";

// A fresh list per call would be a new reference every render, which the
// composer's history reset keys off. The feed has no history to walk: it is not
// a conversation with one agent.
const NO_HISTORY = [];
const NO_COMMANDS = [];
// Likewise the catalog before the read has answered: an empty list, not a
// guessed pair of modes. `ChatInput` renders no selector for it.
const NO_MODES = [];

/**
 * The agent a note goes to when the user has not picked one: the space's root.
 * `parentId == null` is the root — every other agent in the space was spawned by
 * someone — and a space with only children (its root has not appeared yet) falls
 * back to the first row rather than to nobody.
 */
function pickRecipient(agents, chosen) {
  if (chosen && agents.some((agent) => agent.name === chosen)) return chosen;
  const root = agents.find(
    (agent) => (agent.parentId ?? agent.parent_id) == null,
  );
  return root?.name ?? agents[0]?.name ?? null;
}

export function SpaceFeed({ space, blueprint, spaceAgents }) {
  const feed = useStore((state) => state.spaceFeeds[space.id]);
  const me = useStore((state) => state.currentUser?.username ?? null);
  const lobbyJoined = useStore((state) => state.lobbyJoined);

  const [inputValue, setInputValue] = useState("");
  const [sendError, setSendError] = useState(null);
  const [chosenRecipient, setChosenRecipient] = useState(null);

  // Real DOM nodes, not refs, because the notes area is mounted after the first
  // render — the feed starts in `loading` and only later renders its notes — and
  // `useScrollToBottom`'s effects have to re-run when they appear.
  const [scrollContainerEl, setScrollContainerEl] = useState(null);
  const [notesEndEl, setNotesEndEl] = useState(null);

  // The read is one lobby push per visit, so it waits for the lobby to be
  // joined: a push sent before that is refused and would show as a failed read
  // on a page that is only still connecting. Until then the feed says it is
  // loading, which is the truth. Re-reading on every render would replace the
  // list under a note that just arrived; the pushes keep it current in between.
  useEffect(() => {
    if (!lobbyJoined) return;
    requestSpaceFeed(space.id);
  }, [space.id, lobbyJoined]);

  const recipient = pickRecipient(spaceAgents, chosenRecipient);

  // The mode the next note asks for — the same draft the agent page's composer
  // holds, seeded from the space's default rather than from the agent's current
  // mode: this page has no agent channel to report one (`Nest.Modes` and the
  // space's blueprint are what the server sent with the feed).
  const { currentMode, setCurrentMode, handleModeChange } = useAgentMode({
    name: recipient,
    currentModeFromCache: null,
    defaultMode: feed?.defaultMode ?? null,
  });

  const owed = owedAgents(feed?.notes, me);
  const mode = currentMode ?? feed?.defaultMode ?? null;

  // The same follow/pin behaviour the agent page has, over the feed's notes.
  // `feed.notes` is the trigger: the store replaces the array on every push, and
  // the hook keys on that identity change. `space.id` is the reset key, so
  // navigating to another space starts at the latest note instead of inheriting
  // this one's scroll position.
  const { isAtBottom, hasNewContent, jumpToBottom } = useScrollToBottom(
    scrollContainerEl,
    notesEndEl,
    space.id,
    feed?.notes,
  );

  const handleSend = () => {
    const content = inputValue.trim();
    if (!content || !recipient) return;

    setInputValue("");
    setSendError(null);

    sendSpaceNote(space.id, recipient, content, mode, undefined, (err) => {
      setSendError(errorText(err, "Could not send the note."));
    });
  };

  return (
    <div className="flex flex-col h-full max-w-4xl mx-auto overflow-hidden">
      {/* Issue #86, the same defect and the same fix as `ChatPage`: `main` in
          `Layout` scrolls for every page, and on this one that made it a second
          scroll container — chrome taller than the viewport pushed the column
          past it, and scrolling anywhere over the page then took the space's
          name, its environment card and the composer with it. `overflow-hidden`
          keeps the column the page's whole height, so only the regions below
          scroll. This one is the chrome: it fits its content normally, and when
          the banners and the environment card alone are taller than the viewport
          it scrolls on its own rather than being clipped or pushing the composer
          off screen. */}
      <div className="min-h-0 overflow-y-auto">
        <SpacePausedBanner spaceId={space.id} spaceName={space.name} />

        <header className="mb-4">
          <h1 className="text-3xl font-bold text-gray-900">{space.name}</h1>
          {blueprint && (
            <p className="text-sm text-gray-500 mt-1">
              Blueprint: {blueprint.name}
            </p>
          )}
        </header>

        <div className="mb-4">
          <SpaceEnvironmentCard space={space} />
        </div>

        <OwedRepliesBanner agents={owed} onPick={setChosenRecipient} />
      </div>

      {/* One scroll container for every state — notes, loading, failed, empty —
          so the follow/pin behaviour has a single element to track however the
          read is going, and the end anchor is always inside it. `min-h-0` is
          what lets it shrink to the space the chrome and the composer leave: at
          `min-height: auto` it would stay at content height, its own
          `overflow-y-auto` would never engage, and the column's clip would put
          the newest notes out of reach. */}
      <div
        ref={setScrollContainerEl}
        className="flex-1 min-h-0 overflow-y-auto mb-4 pr-2"
      >
        <FeedNotes
          feed={feed}
          me={me}
          onRetry={() => requestSpaceFeed(space.id)}
        />
        <div ref={setNotesEndEl} />
      </div>

      {/* The composer's half of the page, outside both scroll regions: the
          error a send just failed with, the recipient that send will go to, and
          the input itself. None of it may be scrolled or squeezed away — they
          are what the reader acts on next, and the picker is the only control
          that says who the note is for. The input's wrapper is `shrink-0`; the
          banner and the picker are plain blocks, so `min-height: auto` already
          holds them at their content height and the chrome region above is what
          gives up height (and scrolls) when the viewport is short. */}
      <SendErrorBanner message={sendError} />

      <RecipientPicker
        agents={spaceAgents}
        recipient={recipient}
        onChange={setChosenRecipient}
      />

      <div className="relative shrink-0">
        <JumpToBottomButton
          hasNewContent={hasNewContent}
          isAtBottom={isAtBottom}
          jumpToBottom={jumpToBottom}
        />

        <ChatInput
          value={inputValue}
          onChange={setInputValue}
          onSend={handleSend}
          disabled={!lobbyJoined || !recipient}
          placeholder={
            recipient
              ? `Send a note to ${recipient}...`
              : "This space has no agent to send to..."
          }
          modes={feed?.modes ?? NO_MODES}
          mode={mode}
          onModeChange={handleModeChange}
          onModeRestore={setCurrentMode}
          history={NO_HISTORY}
          commands={NO_COMMANDS}
        />
      </div>
    </div>
  );
}

/**
 * The notes, and the three states that are not "no notes".
 *
 * A failed read says so and offers the retry; a read still in flight says so; and
 * an empty feed is only claimed once the server has answered with an empty list.
 */
function FeedNotes({ feed, me, onRetry }) {
  if (!feed || feed.status === "loading") {
    return (
      <p className="py-12 text-center text-sm text-gray-500">
        Loading this space&rsquo;s notes…
      </p>
    );
  }

  if (feed.status === "error") {
    return (
      <div>
        <div
          role="alert"
          className="rounded-lg border border-red-200 bg-red-50 p-4"
        >
          <p className="text-sm font-medium text-red-800">
            The notes in this space could not be loaded.
          </p>
          <p className="mt-1 text-sm text-red-700">{feed.error}</p>
          <p className="mt-1 text-sm text-red-700">
            Nothing is missing from the space itself — this page just cannot
            show what was said in it.
          </p>
          <button
            type="button"
            onClick={onRetry}
            className="mt-3 px-4 py-2 rounded-lg text-sm font-medium text-white bg-red-600 hover:bg-red-700 transition-colors"
          >
            Try again
          </button>
        </div>
      </div>
    );
  }

  if (feed.notes.length === 0) {
    return (
      <p className="py-12 text-center text-sm text-gray-400">
        Nothing has been said in this space yet. Send a note below to start.
      </p>
    );
  }

  return (
    <ul aria-label="Notes" className="space-y-2">
      {feed.notes.map((note) => (
        <NoteCard key={note.id} note={note} me={me} />
      ))}
    </ul>
  );
}

/** One note: who said it to whom, when, what, and whether it awaits an answer. */
function NoteCard({ note, me }) {
  const incoming = isIncoming(note, me);
  const runtime = note.from_kind === "runtime";

  // The card's colour says where it came from at a glance: the runtime's words
  // are not an agent's, and the human's own are not incoming.
  const tone = runtime
    ? "bg-amber-50 border-amber-200"
    : incoming
      ? "bg-white border-gray-200"
      : "bg-blue-50 border-blue-200";

  return (
    <li className={`rounded-lg border p-4 ${tone}`}>
      <div className="flex items-baseline justify-between gap-3">
        <p className="text-xs font-medium text-gray-600">
          {noteDirection(note, me)}
        </p>
        <time className="text-xs text-gray-400" dateTime={note.inserted_at}>
          {formatTimestamp(note.inserted_at)}
        </time>
      </div>

      <p className="mt-2 whitespace-pre-wrap text-sm text-gray-800">
        {note.content}
      </p>

      {note.kind === "query" && (
        <p className="mt-2 text-xs font-medium text-indigo-700">
          {incoming
            ? note.answered_at
              ? "you answered"
              : "waiting for your reply"
            : "waiting for an answer"}
        </p>
      )}
    </li>
  );
}

/**
 * The owed-reply banner: incoming queries that are still unanswered, per agent.
 *
 * Advisory only. It is not a reminder and there is no give-up — a human has no
 * turn to wedge, so there is nothing to protect and nothing to time out. Each
 * agent's name is a button that makes that agent the composer's recipient, which
 * is the one useful thing to do about it.
 */
function OwedRepliesBanner({ agents, onPick }) {
  if (agents.length === 0) return null;

  return (
    <div
      role="status"
      className="bg-indigo-50 border-l-4 border-indigo-400 p-4 mb-4"
    >
      <p className="text-sm font-medium text-indigo-900">
        Waiting for your reply
      </p>
      <ul className="mt-2 flex flex-wrap items-center gap-2">
        {agents.map((agent) => (
          <li key={agent.name}>
            <button
              type="button"
              onClick={() => onPick(agent.name)}
              className="px-3 py-1 rounded-full text-xs font-medium text-indigo-800 bg-white border border-indigo-200 hover:bg-indigo-100 transition-colors"
            >
              Reply to {agent.name}
              {agent.count > 1 ? ` (${agent.count} notes)` : ""}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

/**
 * The composer's recipient: the space's agents, root by default.
 *
 * A `<select>` rather than a row of chips because a space's agent tree is
 * unbounded and the names are the same ones the sidebar shows — this is a
 * choice, not a list to browse.
 */
function RecipientPicker({ agents, recipient, onChange }) {
  if (agents.length === 0) {
    return (
      <p className="pb-2 text-sm text-red-600">
        This space has no agents yet, so there is nobody to send a note to.
      </p>
    );
  }

  return (
    <div className="flex items-center gap-2 pb-2">
      <label
        htmlFor="feed-recipient"
        className="text-xs font-medium text-gray-500 uppercase tracking-wider"
      >
        Send to
      </label>
      <select
        id="feed-recipient"
        value={recipient ?? ""}
        onChange={(event) => onChange(event.target.value)}
        className="px-3 py-1.5 rounded-lg border border-gray-300 bg-white text-sm font-medium text-gray-700 hover:bg-gray-50 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
      >
        {agents.map((agent) => (
          <option key={agent.name} value={agent.name}>
            {agent.name}
            {agent.depth > 0 ? ` (depth ${agent.depth})` : ""}
          </option>
        ))}
      </select>
    </div>
  );
}

export default SpaceFeed;
