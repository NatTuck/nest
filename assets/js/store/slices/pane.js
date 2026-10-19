/**
 * The chat page's right-hand pane: the space's questions for the user (#119)
 * and the current agent's TODO list (#120).
 *
 * The pane is keyed by **space**, not by agent. The questions are the space's
 * — any of its agents may ask one, and the human answers them once — while the
 * `todos` map inside the same payload is keyed by agent name and the pane shows
 * only the list for the agent whose page is open.
 *
 * ## The frame is the whole list, and `seq` is the only ordering
 *
 * Every frame carries the entire list, so this is a reconcile and never an
 * append. It also carries a `seq` that only increases, and a frame whose `seq`
 * is not greater than the last one applied is **dropped**: a late frame that
 * still lists a question the user has just answered would otherwise put it back
 * on screen, and a question coming back is the one removal the UI rule forbids
 * (the user answered it — it must not reappear under their cursor).
 *
 * The reconcile keeps the order the user has been seeing and appends the ids it
 * has not seen yet, in payload order. Replacing the list wholesale would let a
 * server that ordered by recency move a question the user is reading, and the
 * open row and any focus in it are addressed by id precisely so that an append
 * cannot slide them onto a different question.
 *
 * ## Why the browser's own state lives here too
 *
 * `collapsed`, `expandedId`, `drafts` and `marks` are about these same rows:
 * which accordion row is open, what the user has typed, and which save/drop
 * they pressed (a mark stays depressed until the answer changes or the answers
 * are sent). Keeping them in the entry rather than in component state is what
 * makes them survive the panel unmounting — navigating away and back must not
 * forget that the pane was collapsed or what was half-typed into it.
 */

/** The marks a question can carry. Anything else is not a mark. */
const MARKS = new Set(["save", "drop"]);

/** The pane before its first frame. */
const EMPTY_PANE = Object.freeze({
  decisions: [],
  todos: {},
  seq: null,
  collapsed: false,
  // The accordion row the user opened, by id. `null` means "nobody has chosen
  // yet", which the accordion resolves to the first question — never an index,
  // which an appended question would shift.
  expandedId: null,
  // question id -> the answer text the user has typed or picked.
  drafts: {},
  // question id -> "save" | "drop", the control the user pressed.
  marks: {},
  // question id -> {kind: "orphaned" | "failed" | "explained", reason}: what
  // the last answer push said about it, shown inline on that question.
  outcomes: {},
  // The last pane push that failed, as a sentence. Cleared by the next success.
  error: null,
});

const isPlainObject = (value) =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const hasId = (decision) =>
  typeof decision?.id === "string" && decision.id.length > 0;

/**
 * Reconcile a frame's list with the one on screen: keep the order already
 * shown, update each held question from the frame, drop the ones the frame no
 * longer carries, and append the new ones in payload order.
 *
 * A question therefore never moves while it is on screen — the frame can change
 * its body, or take it away, but an arriving question can only be added at the
 * end.
 */
function reconcileDecisions(existing, incoming) {
  const byId = new Map(incoming.map((decision) => [decision.id, decision]));
  const kept = [];
  const seen = new Set();

  for (const held of existing) {
    const fresh = byId.get(held.id);
    if (!fresh) continue;
    kept.push(fresh);
    seen.add(fresh.id);
  }
  for (const decision of incoming) {
    if (!seen.has(decision.id)) kept.push(decision);
  }

  return kept;
}

/** Drop the entries of ids the list no longer holds, so nothing lingers. */
function prune(map, decisions) {
  const ids = new Set(decisions.map((decision) => decision.id));
  const kept = {};
  for (const [id, value] of Object.entries(map)) {
    if (ids.has(id)) kept[id] = value;
  }
  return kept;
}

/**
 * The id of the row to open after `id` is resolved: the next question that
 * carries no mark, wrapping around the end, and — when every question is
 * resolved — the one directly below it, so the accordion always has a row open.
 */
function nextOpenId(decisions, marks, id) {
  const count = decisions.length;
  if (count === 0) return null;

  const at = decisions.findIndex((decision) => decision.id === id);
  if (at === -1) return decisions[0].id;

  for (let step = 1; step <= count; step++) {
    const candidate = decisions[(at + step) % count];
    if (!marks[candidate.id]) return candidate.id;
  }
  return decisions[(at + 1) % count].id;
}

/**
 * How many questions still want the user: the ones with no save/drop mark. A
 * question the agent marked obsolete still counts — the user is the one who
 * decides to drop it — and one the server reported orphaned counts until it is
 * dropped, because it is still sitting there asking for a click.
 */
export function outstandingCount(pane) {
  if (!pane) return 0;
  return pane.decisions.filter((decision) => !pane.marks[decision.id]).length;
}

/**
 * Apply a `decisions:answer` reply: the ids it delivered, refused for a
 * transient reason, or found orphaned.
 *
 * Nothing is removed here. The server broadcasts the list without the delivered
 * questions, and a removal the user did not see a frame for would be this
 * client guessing — the reply says which answers were *delivered*, not that the
 * list on screen is now wrong.
 */
function applyOutcomes(pane, reply) {
  const marks = { ...pane.marks };
  const drafts = { ...pane.drafts };
  const outcomes = { ...pane.outcomes };

  // `delivered` is a list of ids; the two refusals are `%{"id", "reason"}`.
  const delivered = Array.isArray(reply?.delivered)
    ? reply.delivered.filter((id) => typeof id === "string" && id.length > 0)
    : [];
  const refusals = (value) =>
    Array.isArray(value) ? value.filter((entry) => hasId(entry)) : [];

  for (const id of delivered) {
    // Delivered: the answer is the server's now, so neither the mark nor the
    // draft has anything left to say.
    delete marks[id];
    delete drafts[id];
    delete outcomes[id];
  }

  for (const entry of refusals(reply?.orphaned)) {
    // Its asking agent is gone, so the answer can never be delivered: drop the
    // mark (which would offer to send it) and keep the reason on the question,
    // which is now drop-only.
    outcomes[entry.id] = {
      kind: "orphaned",
      reason: entry.reason ?? null,
    };
    delete marks[entry.id];
    delete drafts[entry.id];
  }

  for (const entry of refusals(reply?.failed)) {
    // A transient refusal: the question stays answerable and the draft stays
    // put, so the user can send the same answer again.
    outcomes[entry.id] = { kind: "failed", reason: entry.reason ?? null };
    delete marks[entry.id];
  }

  return { marks, drafts, outcomes, error: null };
}

export function paneSetters(set) {
  return {
    /**
     * One `pane:state` frame, or the reply to `pane:sync` (the same payload).
     *
     * A frame that names no sequence, or that carries something other than a
     * list of questions with ids, is refused with a console warning rather than
     * applied: the pane cannot reconcile against a payload it cannot address,
     * and silently keeping the old list would hide that the server and the
     * browser have stopped agreeing.
     */
    setPaneState: (spaceId, payload) => {
      const seq = payload?.seq;
      const incoming = payload?.decisions;

      if (
        typeof seq !== "number" ||
        !Array.isArray(incoming) ||
        !incoming.every(hasId)
      ) {
        console.warn(`[pane:${spaceId}] unusable pane:state frame:`, payload);
        return;
      }

      set((state) => {
        const prior = state.panes[spaceId];
        // A frame at or below the last one applied is a late frame, and the
        // list it carries is older than what is on screen. Dropped silently:
        // this is ordinary traffic, not a broken server.
        if (prior && typeof prior.seq === "number" && seq <= prior.seq) {
          return state;
        }

        const base = prior ?? EMPTY_PANE;
        const decisions = reconcileDecisions(base.decisions, incoming);

        return {
          panes: {
            ...state.panes,
            [spaceId]: {
              ...base,
              decisions,
              // `null` (rather than `{}`) when the payload did not carry the
              // map, so the list can say it is missing instead of claiming the
              // agent has no TODOs.
              todos: isPlainObject(payload.todos) ? payload.todos : null,
              seq,
              drafts: prune(base.drafts, decisions),
              marks: prune(base.marks, decisions),
              outcomes: prune(base.outcomes, decisions),
            },
          },
        };
      });
    },

    /** Open or close the pane. User state: a frame never changes it. */
    setPaneCollapsed: (spaceId, collapsed) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return {
          panes: {
            ...state.panes,
            [spaceId]: { ...pane, collapsed: Boolean(collapsed) },
          },
        };
      });
    },

    /** The user opened an accordion row. */
    setPaneExpanded: (spaceId, id) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return {
          panes: { ...state.panes, [spaceId]: { ...pane, expandedId: id } },
        };
      });
    },

    /**
     * The answer to one question changed — typed, or picked from the suggested
     * answers — which clears its mark: a save/drop describes the answer it was
     * pressed for, so an answer that has changed since is not resolved.
     */
    setPaneDraft: (spaceId, id, text) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;

        const marks = { ...pane.marks };
        delete marks[id];

        return {
          panes: {
            ...state.panes,
            [spaceId]: {
              ...pane,
              drafts: { ...pane.drafts, [id]: text },
              marks,
            },
          },
        };
      });
    },

    /**
     * The user pressed save or drop on a question: it is resolved, it
     * contracts, and the next unanswered one opens (looping).
     */
    markPaneDecision: (spaceId, id, mark) => {
      if (!MARKS.has(mark)) return;

      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;

        const marks = { ...pane.marks, [id]: mark };

        return {
          panes: {
            ...state.panes,
            [spaceId]: {
              ...pane,
              marks,
              expandedId: nextOpenId(pane.decisions, marks, id),
            },
          },
        };
      });
    },

    /**
     * Release every mark. The user pressed "send answers", so the marks they
     * were pressing have been posted and are no longer depressed. The drafts
     * stay put: a push that fails must not also throw away what was typed.
     */
    clearPaneMarks: (spaceId) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return { panes: { ...state.panes, [spaceId]: { ...pane, marks: {} } } };
      });
    },

    /** The `decisions:answer` reply: what was delivered, refused or orphaned. */
    applyPaneAnswerReply: (spaceId, reply) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return {
          panes: {
            ...state.panes,
            [spaceId]: { ...pane, ...applyOutcomes(pane, reply) },
          },
        };
      });
    },

    /** The answer to `decisions:explain` was accepted; the question stays open. */
    setPaneExplained: (spaceId, id) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return {
          panes: {
            ...state.panes,
            [spaceId]: {
              ...pane,
              outcomes: {
                ...pane.outcomes,
                [id]: { kind: "explained", reason: null },
              },
            },
          },
        };
      });
    },

    /** A pane push failed. `null` clears it after the next successful one. */
    setPaneError: (spaceId, error) => {
      set((state) => {
        const pane = state.panes[spaceId];
        if (!pane) return state;
        return {
          panes: { ...state.panes, [spaceId]: { ...pane, error } },
        };
      });
    },
  };
}
