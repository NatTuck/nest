/**
 * The space feed's cache: the notes at `/space/:slug`, one entry per space.
 *
 * The feed is the space's **note log** — one table (`user_notes`) read by the
 * human at one end of each row — and it is deliberately not the transcript, so
 * none of this touches `agentsCache`. A note is *pushed* here
 * (`user_note:created`) and the whole list is *read* once per visit
 * (`space_feed`), which is why an entry exists only after the feed was opened:
 * a space nobody has looked at needs no incremental cache, and the first read
 * fetches all of it.
 *
 * ## Why an entry is more than a list
 *
 * `status` and `error` are part of the entry because the feed must never render
 * an empty list as "nothing has been said". "Loading", "ready" and "error" are
 * three different things and the page says which one it is; a read that failed
 * leaves `error` set until the next attempt replaces it.
 *
 * `modes` and `defaultMode` ride the read because the feed is the one page with
 * no agent channel behind it: `Nest.Modes` is the server's answer to which modes
 * exist, and the space's blueprint decides which one a message from here asks
 * for by default. The browser decides neither.
 */

/** A feed that has not been read yet. Frozen so `Object.is` can compare it. */
export const EMPTY_FEED = Object.freeze({
  notes: [],
  status: "loading",
  error: null,
  modes: [],
  defaultMode: null,
});

/**
 * Insert `note` into `notes`, in `id` order, replacing any row with its id.
 *
 * `id` is the table's monotonic key, so it is the feed's order and the dedupe
 * key both: a push can arrive before (or after) the read that also contains it,
 * and the two must not show the note twice.
 */
function insertById(notes, note) {
  const at = notes.findIndex((held) => held.id >= note.id);
  if (at === -1) return [...notes, note];
  if (notes[at].id === note.id) {
    return [...notes.slice(0, at), note, ...notes.slice(at + 1)];
  }
  return [...notes.slice(0, at), note, ...notes.slice(at)];
}

export function spaceFeedSetters(set) {
  return {
    /**
     * The read is in flight. A refresh keeps what is already on screen — the
     * page is being revisited, not emptied — and only a first read (or a retry
     * after a failure) shows the loading state.
     */
    setSpaceFeedLoading: (spaceId) => {
      set((state) => {
        const existing = state.spaceFeeds[spaceId];
        if (existing?.status === "ready") return state;
        return {
          spaceFeeds: {
            ...state.spaceFeeds,
            [spaceId]: {
              ...EMPTY_FEED,
              ...existing,
              status: "loading",
              error: null,
            },
          },
        };
      });
    },

    /** The reply to `space_feed`: the whole list, in `id` order, and the modes. */
    setSpaceFeed: (spaceId, payload) => {
      const notes = Array.isArray(payload?.notes) ? payload.notes : [];
      const modes = Array.isArray(payload?.modes) ? payload.modes : [];

      set((state) => ({
        spaceFeeds: {
          ...state.spaceFeeds,
          [spaceId]: {
            notes,
            status: "ready",
            error: null,
            modes,
            // A missing default mode is left as `null` rather than guessed: the
            // mode selector renders an explicit "unknown" for it, and a mode
            // this client invented would be one the server never agreed to.
            defaultMode: payload?.default_mode ?? null,
          },
        },
      }));
    },

    /** The read failed. `error` is a sentence the page shows, not a code. */
    setSpaceFeedError: (spaceId, error) => {
      set((state) => ({
        spaceFeeds: {
          ...state.spaceFeeds,
          [spaceId]: {
            ...EMPTY_FEED,
            ...state.spaceFeeds[spaceId],
            status: "error",
            error: error ?? "Could not load the notes.",
          },
        },
      }));
    },

    /**
     * One `user_note:created` frame.
     *
     * A frame for a space whose feed was never opened is dropped: nothing is
     * showing it, and the first read of that space fetches the whole list
     * including this note. Dropping it also keeps the cache bounded by the
     * spaces the user actually looked at.
     */
    appendSpaceNote: (note) => {
      if (note?.space_id == null || note?.id == null) return;

      set((state) => {
        const feed = state.spaceFeeds[note.space_id];
        if (!feed) return state;
        return {
          spaceFeeds: {
            ...state.spaceFeeds,
            [note.space_id]: { ...feed, notes: insertById(feed.notes, note) },
          },
        };
      });
    },

    /**
     * The human answered `agentName`: every outstanding query that agent sent
     * them is answered.
     *
     * This is what the server does in the same action
     * (`Nest.Notes.mark_answered/3`, inside `Nest.Agents.send_note/6`), and it
     * does not broadcast it — its own doc says the banner is advisory and the
     * read is the authority. So the client applies the action it just performed
     * to its own copy, and the next read confirms it. The timestamp is this
     * browser's clock at the moment of the action; nothing renders it, and the
     * next read replaces it with the server's.
     */
    markSpaceQueriesAnswered: (spaceId, agentName) => {
      set((state) => {
        const feed = state.spaceFeeds[spaceId];
        if (!feed) return state;

        const now = new Date().toISOString();
        const notes = feed.notes.map((note) =>
          note.kind === "query" &&
          note.to_kind === "user" &&
          note.from_kind === "agent" &&
          note.from_name === agentName &&
          !note.answered_at
            ? { ...note, answered_at: now }
            : note,
        );

        return {
          spaceFeeds: { ...state.spaceFeeds, [spaceId]: { ...feed, notes } },
        };
      });
    },
  };
}
