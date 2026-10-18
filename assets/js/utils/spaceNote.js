/**
 * How a `user_notes` row reads to the human whose feed it is.
 *
 * The feed renders one table's rows and nothing else, so everything a card shows
 * is derived from the row: who it is from, who it is to, and whether it is still
 * waiting for an answer. Kept out of the components so the wording is testable on
 * its own and both the feed and its banner agree about it.
 *
 * The vocabulary is the header vocabulary the model reads (`[From agent
 * crazy-dolphin]`, `[From nest runtime]`, `@nat` for a human) rather than a
 * second one invented for the screen: a human is `@name` everywhere, and the
 * sigil is what tells them apart from an agent of the same name.
 */

/**
 * One end of a note, in the user's terms: `you`, `@alice`, `agent worker`,
 * `nest runtime` (naming the agent the runtime is speaking about when the row
 * carries one).
 *
 * `me` is the current user's username. When it is not known yet, a human still
 * reads as `@alice` — the truth, just without the "that's you" — and nothing
 * else changes.
 */
export function noteEnd(kind, name, me) {
  if (kind === "user") {
    // `from_name` is nullable in the schema even though every producer passes a
    // string today, so an unnamed human is shown as one rather than rendered as
    // `@null` — the project rule is that missing data gets a visible marker, not
    // a silent gap or a plausible-looking wrong value.
    if (!name) return "a human (unnamed)";
    return name === me ? "you" : `@${name}`;
  }
  if (kind === "runtime") {
    return name ? `nest runtime (about ${name})` : "nest runtime";
  }
  return name ? `agent ${name}` : "agent (unnamed)";
}

/**
 * A whole note's `from … → …` line.
 */
export function noteDirection(note, me) {
  return `from ${noteEnd(note.from_kind, note.from_name, me)} → ${noteEnd(
    note.to_kind,
    note.to_name,
    me,
  )}`;
}

/**
 * Whether the note is addressed to the human reading the feed.
 *
 * `to_kind` alone is not enough: a note this human sent to *another* human is
 * `to_kind: "user"` too. Both ends are named, so both are compared.
 */
export function isIncoming(note, me) {
  return note.to_kind === "user" && note.to_name === me;
}

/**
 * The notes still waiting for this human's answer: incoming `:query` rows whose
 * `answered_at` is null.
 *
 * Advisory only — a human has no turn to wedge, so there is nothing to time out
 * and no reminder to send (`notes/space-chat.md`). The clear is the human's own
 * note back to that agent, which the server marks (`Nest.Notes.mark_answered/3`)
 * and which the feed applies to its own copy as it sends.
 */
export function owedQueries(notes, me) {
  return (notes || []).filter(
    (note) =>
      note.kind === "query" && !note.answered_at && isIncoming(note, me),
  );
}

/**
 * The agents those queries came from, one entry per agent, oldest first — what
 * the owed-reply banner names and what its buttons select as the recipient.
 *
 * Only an **agent's** query is here: it is an agent that is waiting on a reply
 * and an agent that the composer can send one back to. A query from another
 * human is still a note in the feed; it is not an agent with a turn to answer
 * from this page.
 *
 * `count` is how many queries that agent is still waiting on, because one agent
 * can ask twice.
 */
export function owedAgents(notes, me) {
  const agents = new Map();

  for (const note of owedQueries(notes, me)) {
    if (note.from_kind !== "agent" || !note.from_name) continue;
    const held = agents.get(note.from_name);
    agents.set(note.from_name, {
      name: note.from_name,
      count: (held?.count ?? 0) + 1,
    });
  }

  return [...agents.values()];
}
