/**
 * The composer's transient state: what is half-typed in each input box.
 *
 * A draft belongs to the thing being written *to*, not to the component that
 * renders the box — the chat composer is per agent, the space feed's is per
 * space. Keying it here is what makes leaving and returning restore a
 * half-typed message, and, just as important, what stops one agent's draft
 * appearing in another's box: `ChatPage` stays mounted when the route's `:name`
 * changes, so a draft held in that component's own state would move with the
 * reader.
 *
 * Empty string is the sent state, not a deletion — a box that was just cleared
 * must render empty rather than fall back to something older.
 */

/** The key a space feed's draft is held under, distinct from any agent name. */
export function spaceDraftKey(spaceId) {
  return `space:${spaceId}`;
}

export function composerSetters(set) {
  return {
    /**
     * Set the draft for `key` — an agent name, or `spaceDraftKey(spaceId)`.
     * The send path calls this with `""`.
     */
    setDraft: (key, text) => {
      set((state) => ({ drafts: { ...state.drafts, [key]: text } }));
    },
  };
}
