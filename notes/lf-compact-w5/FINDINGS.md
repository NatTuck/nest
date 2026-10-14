# W5 / #98 — the `/compact` request as a visible message: BLOCKED

**Outcome: stopped and reported, per the brief.** The change was implemented, and
it **breaks compaction**. Production code is restored; the attempted diff, the
reproduction test and the failing log are in this directory.

## What was tried

Append the `/compact [focus]` request as an ordinary human `{:user, %User{}}` —
the same shape `ChatPipeline.build_user_message/3` gives a typed message, so it
renders, persists, and reaches the Ctrl/Cmd+Up recall list — at the moment
`Transitions.do_step(%{phase: :idle}, {:compact_request, focus})` stages the
compaction. See `attempted.diff`.

## Why it fails

Every `/compact` dies with:

```
Compaction failed: Refusing to send an invalid message sequence (wire preflight):
alternation: consecutive same-role messages at 2
```

The mechanism, verified by reading the code paths:

1. `Compaction.do_stage/2` → `Dispatch.compaction_plan/1` → `stage_request/2`
   decides whether a `synthetic_assistant_bridge/0` is needed by asking
   `MessageList.last_wire_role/1` about the context **as it is at planning time**.
   For a fresh agent the tail is the system message, so no bridge is planned and
   `staged == [suffix]`.
2. The append action this change adds then runs, so the agent's message list
   gains the request row.
3. `Turn.prepare/1` (`lib/nest/agents/agent/turn.ex:257-267`) rebuilds
   `work.ctx` from Agent state **"before every step"** — so by the time the
   `:iterate` step builds the request, `work.ctx.messages` ends with the request
   row.
4. `Dispatch.request_messages/1` returns `base ++ staged` =
   `[system, user(request), user(suffix)]` — two adjacent user messages, which
   the wire-alternation invariant rejects.

So the planner's bridge decision and the request's base disagree, because the
context is rebuilt between them and this change is the first thing to append
inside the turn that plans the compaction. It is a **latent fragility the change
trips**, not a mistake in the change: `stage_request/2`'s decision is made
against a snapshot that can move before the request is built.

## The two ways out, and why neither is in scope

* **(A) A request-path exclusion filter.** A role (or a metadata marker) that
  `Dispatch.request_messages/1` drops. This satisfies "visible but never sent"
  exactly, but it is a **second** LLM-visibility mechanism: the existing one is
  positional (`:compaction` is non-LLM-visible only because it sits below
  `last_compaction_index`; see `Nest.Messages.Compaction`'s and
  `ChatState`'s moduledocs, and note that `Turn.build_ctx/2` →
  `messages: state.chat_state.messages` with no filter anywhere on the request
  path). The brief says to reuse the existing mechanism rather than invent a
  second one.
* **(B) Make the planner's base and the request's base agree** — carry the
  planned base, or move the bridge decision to `request_messages/1` where the
  base is known. Small, and arguably the right fix for the latent fragility, but
  `synthetic_assistant_bridge/0` is documented as *"persisted with the summary on
  a successful commit"*, so moving it changes the persisted summary shape — a
  change to the compaction commit that this item does not authorise.

## Findings on the brief's four questions

1. **Role/shape.** A human `{:user, %User{}}`, not a new role. A new role would
   need `Message.role`, `Message.to_json`, a new struct, `Preflight`'s
   `@known_roles`, `Sanitize`, `PersistedMessage` and the UI — and would still be
   *sent*, since no role is filtered.
2. **How LLM-visibility is enforced.** By **position**, not by a filter: the
   request is `chat_state.messages`, and `:compaction` is never in it because the
   boundary rule (`messages = rows where message_index > last_compaction_index`)
   puts the marker in the archived slice. There is no role filter to reuse.
3. **Sequence invariants.** Enforced at append time (`Repair.decide/2` via
   `MessageAppender`) *and* on every request (`Preflight.validate_request/1`).
   `MessageAppender` explicitly supports a `{:user, _}` append at a terminal
   boundary (idle) — that half is fine. The wire alternation rule is what fails,
   and it fails because of the two-role collision above, not because the append
   is illegal.
4. **Body / no focus.** `/compact <focus>` and `/compact` are the natural bodies;
   the mode prefix (`[mode: <mode>]\n`) is added to match every other human row,
   and `metadata["mode"]` + `origin: "human"` match `build_user_message/3`.
5. **Client presentation.** No client work is needed: a `{:user, _}` row already
   renders, and after the compaction it lands in the archived slice next to the
   marker, which `CollapsedHistory.jsx` / `CompactionMarker.jsx` already render.
   `compactAgent/3` stays control-plane; the row is built server-side.

## Recommendation

Take (B) as its own small, separately-reviewed change — *"the compaction request
must be built from the base it was planned against"* — and land #98 on top of it.
That fixes the latent fragility on its own merits and makes this item a
two-line change. (A) should stay rejected: a permanent filter on what the model
sees, maintained forever, to serve one row.
