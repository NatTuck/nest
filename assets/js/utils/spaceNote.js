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
 * The notes still waiting for this human's answer: incoming `:query` rows with
 * neither `answered_at` nor `dismissed_at` set.
 *
 * Advisory only — a human has no turn to wedge, so there is nothing to time out
 * and no reminder to send (`notes/space-chat.md`). Two clears, and they are
 * different facts: answering is the human's own note back to that agent, which
 * the server marks (`Nest.Notes.mark_answered/3`), and **ignoring** is
 * `dismissed_at` (`Nest.Notes.dismiss_queries/3`), which the banner's Ignore
 * button sets. The feed applies both to its own copy, because neither is
 * broadcast.
 */
export function owedQueries(notes, me) {
  return (notes || []).filter(
    (note) =>
      note.kind === "query" &&
      !note.answered_at &&
      !note.dismissed_at &&
      isIncoming(note, me),
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
 * can ask twice, and `ids` are those rows — what the banner's Ignore dismisses.
 * The ids are the ones this projection selected, so a query that arrives after
 * the banner was drawn is not among them and cannot be dismissed unseen.
 *
 * `archived` is the set of agent names that are archived, and an **archived agent
 * owes nothing**: its process is stopped, so there is no turn for this page to
 * answer and no note the human could send that would clear the query. Leaving it
 * in would put a reply button on the banner that cannot do anything — a number
 * that is still arithmetically true and no longer means what the banner says. So
 * the filter belongs here, in the projection, rather than at the banner: the fact
 * is that the agent owes nothing, not that the banner should keep quiet about it.
 */
export function owedAgents(notes, me, archived) {
  const agents = new Map();

  for (const note of owedQueries(notes, me)) {
    if (note.from_kind !== "agent" || !note.from_name) continue;
    if (archived?.has(note.from_name)) continue;
    const held = agents.get(note.from_name);
    agents.set(note.from_name, {
      name: note.from_name,
      count: (held?.count ?? 0) + 1,
      ids: [...(held?.ids ?? []), note.id],
    });
  }

  return [...agents.values()];
}

/**
 * Which of a `query` row's five states it is in, as a fact rather than a
 * sentence — so the card and the banner cannot disagree about what is owed.
 *
 *   * `answered` — the human answered it (`answered_at` is set).
 *   * `dismissed` — the human ignored it (`dismissed_at` is set): not owed any
 *     more, and not answered either. It outranks `archived` below because it is
 *     the human's own decision about the note, and it is only reachable while
 *     `answered_at` is null — the server clears one when it sets the other.
 *   * `owed` — incoming, unanswered and not ignored: this human's to answer, and
 *     `owedAgents` names it in the banner.
 *   * `archived` — incoming and unanswered, but the agent that asked is
 *     archived. The row's own truth is unchanged (nobody has answered it), which
 *     is what the card says; what it must not do is *invite* a reply, because an
 *     archived agent's process is stopped and nothing the human sends can clear
 *     the query. `owedAgents` leaves it out of the banner for that reason, and a
 *     card that asked for the reply anyway would contradict the banner three
 *     lines above it.
 *   * `awaiting` — a query the human sent, waiting for the other end's answer.
 *
 * `archived` is the same set `owedAgents/3` takes.
 */
export function queryReplyState(note, me, archived) {
  if (!isIncoming(note, me)) return "awaiting";
  if (note.answered_at) return "answered";
  if (note.dismissed_at) return "dismissed";
  if (note.from_kind === "agent" && archived?.has(note.from_name)) {
    return "archived";
  }
  return "owed";
}
