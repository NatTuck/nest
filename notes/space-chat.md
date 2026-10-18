# The space's own page: notes, addressees, headers

A space has agents and a human. Today the human reaches an agent through that
agent's own chat page (`/space/:slug/agent/:name`), and an agent cannot address
the human at all. This note designs both halves of the fix: `/space/:slug`
becomes the space's own page — a **feed** of the notes the human sent and the
notes agents sent to the human — and the human becomes an **addressee** with a
name agents can send to.

It is a design note: the decisions below were settled, the residuals section
says what is still open and which of those needs the user's word, and the last
section bounds the work. The order the code lands in is the implementer's to
choose — the prerequisites are called out where they bite.

## Three words, one job each

"Message" is overloaded: it is the row an LLM sees, and it is also what one
agent sends another. Those are different things, and the difference is not
cosmetic.

| word | what it is |
|---|---|
| **message** | a row in `messages` — what an LLM sees |
| **note** | the transport unit: sender, recipient, kind, content |
| **notice** | a marker on a runtime note's text, not a thing |

A message lives in `Nest.Messages` (`MessageList`, `MessageAppender`,
`Part`). A note lives in the inbox until a drain turns it into a message. A
notice is `Nest.Messages.NoticeTag`'s `[nest notice]`, and it exists only as
text.

The fact that justifies the split: **N notes become 1 message.** A drain takes
a run of leading inbox entries and joins their bodies into a single user-role
message (`Inbox.batch/1`, `Inbox.Render.combine/1`, then
`build_drained_message/3`). Many-to-one. A note and a message cannot be the
same word, and "notice" cannot be either of them: it is a marker on some
notes' text, not a kind of thing.

The vocabulary is already right where it counts. `MessageList`,
`MessageAppender`, `build_drained_message/3` and `Part` name the LLM-facing
row; `Inbox.entry` and the tool argument `to` name the transport unit. What is
wrong is three names that mix the two.

### The rename

| now | becomes |
|---|---|
| `kind: :notice` | `kind: :runtime` |
| `Agents.send_message/6` | `Agents.send_note/6` |
| `Agent.deliver_message/5` | `Agent.deliver_note/5` |
| `Inbox.entry` | the note |

The first is the only one that carries meaning. With it, the four kinds
answer one question — *from whom*: `:agent | :user | :query | :runtime`.
Today three answer that and the fourth names a *speaker*, so a runtime note
and an agent note cannot be told apart by kind alone.

Mechanical and wide: the three names appear **145 times across 44 files** in
`lib`, `test` and `assets` — the `:notice` kind is 74 of those, across 25
files, plus the string `"notice"` it becomes on the wire. Treat that as a
survey, not a promise. Most of a rename that misses a pattern match fails to
compile, which is the right failure mode; the two that do not are named here
rather than left to be found:

* `Inbox.enqueue_internal/5`'s `when kind in [...]` guard — every runtime
  producer funnels through it, so a miss refuses entries at runtime while
  assertions that only look at messages still pass;
* the string `Inbox.serialize/1` puts on the wire, which no atom grep finds.

After the rename exactly two `:notice` atoms remain in `lib`, both the pair
spec's `required(:notice)` text field. That is a useful landmark: a later
`grep :notice` in `lib` returns the marker's, not the kind's.

`:notice` → `:runtime` is the only one that carries meaning. The kind is read
by the inbox's renderer, by the watch and timeline bookkeeping and by
`Machine.Delivery`; every one of those reads *the kind*, never the atom's
spelling, so the rename is mechanical. What it buys is that the kind stops
being a synonym for the marker: after it, `:runtime` says *the runtime spoke*,
and `[nest notice]` — a separate thing — says *this text is the runtime's*.

## Humans are addressees, not agents

### The address

The address is **`@<username>`**. Names are restricted to `[a-z0-9_-]+` — no
spaces, no dots, no capitals — so `@nat` tokenises as one token wherever an
address is written: a tool argument, the composer's recipient field, a
`[From …]` header.

**The charset is the same for humans and agents, and it is lowercase for
both.** Today `Accounts.User` folds to lowercase and agent names do not, so
`@Nat` and `@nat` are one human while `Nat` and `nat` are two agents. One rule
is worth more than the compatibility.

The rule moves to a shared **`Nest.Name`**, consumed by both `Accounts.User`
and `PersistedAgent`, so the two cannot diverge. A sanitising migration brings
existing names up to it, in the shape of
`20261011000000_sanitize_agent_names.exs`: a deterministic transform
(NFD-fold, lowercase, runs of other characters to `-`, trim). It **refuses to
run** rather than silently merging two rows into one name.

Agent names are not only labels, and that is what makes this migration more
than cosmetic: an agent's name is its scratch directory's segment, so a
lowercased name is a **different directory**. The migration must either move
`/tmp/<old>` to `/tmp/<new>` or refuse that agent — and on a `none` space the
scratch is the host's real `/tmp` behind a `.nest-scratch` marker, so a move
there moves host state. Which of the two it does is still open (see residuals);
it gates the migration, not the rest of the PR.

Transcripts are not rewritten. A message written before the migration names the
old spelling, and that is a record of what was said rather than a live address.

**No namespacing machinery, and no cross-table uniqueness check.**
`PersistedAgent`'s name format is `[a-z0-9_-]+`, so `@nat` — the address,
sigil included — is unrepresentable as an agent name. A human and an agent may
both be called `nat`; the sigil is what tells them apart, and it is the *only*
thing that does (see "residuals" for what that costs). In `user_notes` the
`to_kind`/`from_kind` columns carry that distinction into data, which is why
they are not redundant with the names beside them.

### The rejected alternative: an `agents` row

The obvious implementation is to make the human an agent row with no process.
It is rejected, and the reason is the second-spelling problem this codebase
forbids: a row that is not a process is a row every process-enumerating query
must exclude.

The list, none of it hypothetical:

* `LobbyChannel`'s `fetch_broken_agents_async/3` — a row with no process is
  *permanently broken*, so the lobby would show the human a red dot forever;
* `LobbyChannel.visible_agents_across_spaces/2` and the sidebar tree — the
  human would appear as an agent in every space they belong to;
* `agents-list` — an agent would be told it may spawn or query the human;
* `Spaces.stop_space_agents/1` — archiving a space would try to stop the human;
* the spawn-depth logic — a human row would have a depth;
* `nest.repair_messages`' sweep — the worst one: it repairs the
  user/assistant alternation invariant, so a human's "inbox" (a transcript
  with no assistant turns) would be *fabricated assistant acks*, writing
  messages the human never sent;
* and every other place that enumerates `agents` rows.

The count is not stable, which is the point: each one is a place to forget, and
the failure mode of forgetting is a visible bug in a different feature. The
human is an **addressee**, not an agent.

### What a note to a human is

A new table, **`user_notes`**, and it is **addressed, not mailbox-owned**. A
note has a sender and a recipient and both are named; there is no owning
`user_id`. That is what makes a note between two humans one row rather than two
mirror rows.

| column | meaning |
|---|---|
| `space_id` | the space |
| `from_kind` | `agent \| user \| runtime` |
| `from_name` | the agent's name, the username, or `nil` |
| `to_kind` | `agent \| user` |
| `to_name` | the agent's name or the username |
| `content` | the body as written: no header, no marker |
| `kind` | `:query`, `:agent`, `:runtime` … |
| `inserted_at` | when it was written |
| `answered_at` | when a query was answered (see below) |

**`to_kind` is not redundant with `to_name`, and the shared name is why.** An
agent and a human may both be called `nat`; `(to_kind: :agent, to_name: "nat")`
and `(to_kind: :user, to_name: "nat")` are different addressees, and the sigil
never enters a column. Storing `@nat` in `to_name` instead would put the
address's syntax into data.

**The table only holds rows with a human at one end.** Agent-to-agent notes
never enter it: they are the inbox's, and a copy here would be a second
spelling of what an agent was told.

The feed is therefore "rows in this space where I am one end", ordered by `id`
— a bitmap OR over two indexes:

* `user_notes(space_id, to_kind, to_name, id)`
* `user_notes(space_id, from_kind, from_name, id)`

There is **no `read_at`**: per-item read tracking has no UI behind it, so a
column for it would be a guess. `answered_at` is set when the human sends a
note back to that agent, and the advisory banner reads incoming `:query` rows
with it null. The second candidate trigger — "any note from that agent to the
human" — is cheaper and wrong: it clears the banner on a note that answered
something else.

`send_note/6` gains exactly one clause: a target that resolves to a human
address persists a row in `user_notes` and broadcasts, instead of calling
`Supervisor.get_agent/2`. There is no process to call, no inbox to drain and no
transcript to append to — a note to a human is a row and a frame. A
human-to-human note is the same clause with `from_kind: :user`, and reaches
both feeds through the two predicates above.

The rest of the design follows from "no process", and each item is a place
where the agent-shaped assumption would otherwise leak:

* **`agents-list` includes the space's human addresses**, marked unambiguously
  as human, so an agent can discover `@nat` with no prompt change. A prompt
  that named the human would go stale the moment someone joins the space. One
  human is a line in the existing result; several humans would need a different
  shape, and this note does not build for that.
* **`agents-wait` on a human returns immediately** — a human is never mid-turn,
  so there is nothing to wait for. Returning `:ok` is the honest answer; an
  error would teach the model that the address is wrong.
* **`agents-last-message` is not extended.** It is being deleted (#113, already
  merged), and the feed is the human's read path.
* **The owed-reply banner is advisory only**: no reminders and no give-up,
  unlike `Machine.owed_replies` — a human has no turn to wedge, so there is
  nothing to protect and nothing to time out.
* **A give-up note's `from_name` is the agent that did not answer**, with
  `from_kind: :runtime` so the header still reads `[From nest runtime]`. The
  name is what the feed groups by and what the body says.

## The conversation loop

### The human's turn is a query

The space page's composer sends a **query**:

```elixir
send_note(space_id, "@nat", target_agent, content, :query, mode)
```

It is a `:query` and not a `:user` note for one reason: a query is what makes
the recipient *owe* a reply, and an agent that owes `@nat` a reply is an agent
that will answer.

### The reply is cooperative, not automatic

**Rejected: delivering a turn's response to the human automatically.** The
human's words: "Just taking some turn's response is ambiguous and frequently
wrong." A turn is not a reply — it may end in a tool call, a compaction, a
hand-off to a child, or nothing the human asked about. Picking one assistant
message out of it and calling it the answer would be a guess.

So the reply is the agent's own decision, made with `agents-send`. And that
costs no new machinery:

* `Machine.owed_replies` keys on the **sender name**, so `@nat` is a key like
  any other. The agent is reminded it owes a reply, and discharges the debt by
  sending one back: `Machine.discharge_reply/2`'s doc already says it is "the
  clear a successful outbound `agents-send` to that sender performs". That
  send is the `user_notes` row the feed reads.
* `Machine.GiveUp` already notifies the requester when a debt is dropped, and
  for `@nat` that notification *is* a note (`kind: :runtime`), so the feed
  shows "agent X did not reply to your query". **The failure path is free.**

### A human's words never merge into a batch

`Inbox.batch/1` already delivers a lone `:user` head alone:

```elixir
def batch([%{kind: :user} = head | _rest]), do: [head]
def batch(entries), do: Enum.take_while(entries, &(&1.kind != :user))
```

That rule is about **human words**, not about the kind — so it extends from
the kind to the sender: a note whose sender is a human is never merged into a
queued peer batch. Otherwise a human's message merges into a batch of peer
traffic and loses its own turn boundary, which is the one thing the rule
exists to preserve.

## Headers

### The format

Every **user-role** row states who is speaking. A batch states each body's
sender; a single-sender row states it once.

```
[From user @nat | mode: act]
[From user @nat, agents-send reply required | mode: act]
[From agent crazy-dolphin | mode: plan]
[From agent crazy-dolphin, agents-send reply required | mode: plan]
[From nest runtime | mode: act]
[From nest runtime | mode: compact]
```

`agents-send reply required` maps to exactly **one predicate**: `kind ==
:query`. It is a statement that *this* note obliges an answer, which is what
`Machine.owe_replies/2` already keys on. The compaction request gets no marker:
the response it wants is the model's own turn, not an `agents-send`.

The mode is the **recipient's** mode at delivery — the mode the turn will run
in — exactly as `[mode: X]` states it today. Nothing about the mode machinery
changes; the header carries it.

### One builder, and why that is a rule

There are two spellings of the same construction today:
`ChatPipeline`'s private `build_user_message/3` and
`Dispatch.build_user_message/3`. They must collapse into one, and this is a
requirement rather than tidying:

**The spawn kickoff is a message when the child is idle and a note when it is
busy.** `SubAgent.handle_spawn_request/3` calls `Agents.chat/6` for the
`query`; `chat_or_queue/5` sends an idle agent straight to `ChatPipeline`
(no inbox entry, no drain) and a busy one to `Inbox.deliver_user_message/5`
(a note, rendered by the drain). A header owned by the note renderer would
leave the **idle** path unheadered — which is the common case for a spawn.

Two prerequisites:

* **`sender` is threaded into `ChatPipeline.handle_chat/4`.** `Callbacks`
  currently drops it on the idle arm (`handle_chat(state, content, mode,
  human?)`), so the idle path has no sender to state. The same change is what
  makes the human's own sender persistable on a direct chat.
* **`SubAgent.handle_spawn_request/3` passes `state.name`** as the sender, so a
  child's first row reads `[From agent <parent> | mode: X]`. Today the child
  learns its parent from nowhere: `SystemPrompt.identity_section/2` says
  "Your name is … You are at spawn depth N of M" and nothing else about who
  started it.

The marker is a statement **at delivery**, not a standing obligation: a given-up
debt does not retract it, and a late `agents-send` still works.

### Step 2 of the same PR: retire the markers the header replaces

With a header on every user row, three mechanisms become redundant:

| retire | because |
|---|---|
| `[nest notice]`, `NoticeTag` | the header states it |
| `[mode: notice]` and its metadata | it only made the stripper strip |
| the `[mode: X]` prefix | the header carries it |

`origin` comes from `metadata`, not from the marker, so deleting the marker
loses nothing a reader uses. The fake `mode: "notice"` metadata existed only so
`stripModePrefix` would strip a notice's prefix; with one stripper that name
has no job left.

`stripModePrefix.js` and `stripNoticePrefix.js` collapse into one header
stripper, used by `formatMessage`, `chatHistory`, `messageParts` and
`agentHeader`.

**Two documents state the retired rules and must change in the same PR**:
`AGENTS.md` ("System notices should be tagged with a `[Nest notice]` prefix",
and the `[mode: $MODE]` / `[Message from agent …]` section) and
`notes/modes.md` (the same two, with the reasoning). `AGENTS.md` is
human-authored and read-only to agents, so that edit is the user's; leaving it
stale would leave the next agent following a rule the code no longer has.

**The one shape that did not fit is fixed by changing the shape.** The
`NoticePairInjector`'s `:user_agent` form used to fuse `[assistant(notice +
ack)]` when the trailing row was user or tool, because emitting a user row there
would give `user → user`. That assistant row carried a runtime notice where a
`From …` header does not apply — the impersonation problem the marker existed to
solve. It now emits an explicit bridge instead, so every runtime notice is a
user row and the header always applies. See residuals for the shape and what it
costs.

## The feed

### What `/space/:slug` becomes

`/space/:slug` **becomes** the feed. It carries:

* the **composer** — a query to the selected agent;
* the **recipient picker** — the space's agents, root by default;
* the **mode draft** — the same draft-not-push selector the agent page has;
* the **owed-reply banner** — incoming queries not yet answered (advisory);
* the space's **environment and its edit entry** — the workspace, the network,
  the sandbox backend, and `EditSpaceDialog`;
* the **pause banner** (`SpacePausedBanner`) — a held space is held for every
  page of it.

**What it does not show**: tool calls, tool results, thinking blocks,
compaction markers, a compaction request, or any turn that was not a note. All
of that is the agent page's, and putting it in the feed would make the space
page the transcript it is deliberately not.

`main_view_config.view == "rpg"` still renders `RpgPlayInterface` on that route,
unchanged: a campaign's main screen is not a note log.

The **root-agent redirect goes away**. `/space/:slug` no longer redirects to
`/space/:slug/agent/:root` (#96); the feed is what clicking a space gets you.

**`/space/:slug/overview` is retired too.** The feed carries the environment
card and `EditSpaceDialog`, so the overview would be a second page for the same
content with nothing linking to it; its agent list is the feed's recipient
picker. Two routes remain, and the next section is why they must not converge.

### Two routes, two meanings

| route | what it is |
|---|---|
| `/space/:slug` | the space's **note log** |
| `/space/:slug/agent/:name` | that agent's **own conversation** |

They are not two views of one thing and must not converge: the feed answers
"what did we say to each other", and the agent page answers "what did this
agent do" — every turn, tool call, thinking block and job. An agent's reply to
a human appears in both, for different reasons: in the feed because it was said
to the human, in the agent's page because it was an `agents-send` tool call in
that agent's turn.

### Ordering

The **feed** is one table, so its `id` is already monotonic and that is the
order: `ORDER BY id`, with `inserted_at` for display only.

An **agent's page** is `messages`, whose `inserted_at` is `:utc_datetime` —
whole seconds — so it orders by `(inserted_at, id)`: `id` is the tiebreaker
between rows written in the same second. New indexes:

* `messages(agent_id, inserted_at)` — an agent's page;
* `user_notes(space_id, to_kind, to_name, id)` and
  `user_notes(space_id, from_kind, from_name, id)` — the feed's two predicates,
  each already in `id` order so the bitmap OR needs no sort.

### Where each direction is read from

Every direction of the feed reads **one table**: `user_notes`. The transcript
is the agent's record, not the human's.

| direction | the feed reads | also written |
|---|---|---|
| human → agent | `user_notes` | a `:user` row in the target's transcript |
| agent → human | `user_notes` | nothing |
| human → human | `user_notes` | nothing |

Every `user_notes` write is `send_note/6`'s. The outgoing note's second copy is
the message the model reads, carrying the `[From user @nat …]` header; the
incoming note has no second copy because a note to a human enters no transcript
at all. A human-to-human note has one copy and two readers, through the two
indexes above.

That is not duplication, and the distinction matters because it is easy to
mistake for it:

* the **outgoing** direction writes two copies of one note, at one moment, for
  two different readers — the model's conversation and the human's log. They
  are not the same read: the transcript row has no recipient and no
  `(space_id, to_kind, to_name)` index, so a feed built on `messages` would
  have to fan out over every agent's transcript and filter by
  `origin: "human"` — and today it could not even say *which* human, because
  the sender is not persisted (that is the prerequisite above);
* the **incoming** direction has one copy because there is nowhere else to put
  it: a note to a human enters no transcript at all.

## Residuals

**Open, and needing the user's word:**

* **The name migration and the scratch directory.** An agent's name is its
  scratch directory's segment, so lowercasing it is not a label change. The
  migration must either move `/tmp/<old>` to `/tmp/<new>` or refuse that agent;
  on a `none` space the scratch is the host's real `/tmp` behind a
  `.nest-scratch` marker, so a move there moves host state. Undecided. It gates
  the migration, not the rest of the PR.

**Decided, and recorded because each is easy to undo by accident:**

* **The fused assistant row is replaced by an explicit alternation bridge.**
  `NoticePairInjector`'s `:user_agent` shape used to emit one
  `[assistant(notice + ack)]` row when the transcript tail was user or tool.
  That put the runtime's words in an assistant row — impersonating the agent in
  the *last* row the model reads before it acts — and gave the runtime's notice
  two identities, since the same injection already emits a user row when the
  tail is assistant. It now always emits
  `assistant(bridge) → user(notice) → assistant(ack)`.
  `MessageList.pairing_bridge/2`'s `{:user, _} | {:tool, _}` clause already
  returns exactly the bridge row and `bridge_ack_kind/1` falls through to
  `:live`, so neither needs changing. **Two sites, not one**: `build_pair/3`'s
  `:user_agent` clause and `notice_record/3`, which falls back to
  `build_single_assistant(NoticeTag.tag(...))` when `build_pair` defers (the
  `:stop_cancellation` path). The trailing ack is structural rather than
  decorative: the shape ends a turn, so the row after the notice must be
  `assistant` or the next turn's user message gives `user → user`. The cost is
  two synthetic rows and one extra fabricated ack on a rare path — context
  thresholds, budget, stop cancellation, backgrounded completion — paid for one
  identity for the runtime's voice. Rejected: routing `:user_agent` through
  `:agent_user` and iterating, which is the most semantically clean shape but
  costs a full LLM call per notice, exactly what `:user_agent` exists to avoid.
* **`/space/:slug/overview` is retired**, and `/space/:slug` is the feed. Two
  routes remain: the feed and the agent page.
* **No `read_at`.** Per-item read tracking has no UI behind it; `answered_at`
  stays and is what the advisory banner reads.
* **`user_notes` is addressed, not mailbox-owned**: `from_kind`/`from_name`/
  `to_kind`/`to_name`, no `user_id`. One row per note, so a human-to-human note
  is one row rather than two mirrors.
* **The table holds only rows with a human at one end.** Agent-to-agent notes
  are the inbox's.
* **The sigil is required for a human.** A bare name that matches no agent is
  an error naming both possibilities ("no agent `nat`; did you mean the human
  `@nat`?").
* **All names are lowercase**, humans and agents alike.
* **The give-up note's `from_name` is the agent that did not answer**, with
  `from_kind: :runtime` so the header still reads `[From nest runtime]`.
* **A human may address another human**, and both feeds read the one row.
* **`agents-list` names humans unambiguously** and does not grow a shape for
  several of them; one human is a line in the existing result.

**Worth watching:**

* **Lowercasing is a visible change to existing accounts and agents.** The
  migration folds `Jane Doe` to `jane-doe`, and refuses to run on a collision
  rather than merging. Every renamed account's address changes with it, and
  anyone who has been addressed as `@Jane Doe` (impossible under the new rule)
  has no equivalent. The migration's own doc says the rewrite is user-visible;
  this note repeats it because the *address* is what agents will write.
* **A human and an agent may share a name.** `nat` the agent and `@nat` the
  human are distinguishable only by the sigil. That is unambiguous, but it is
  not self-explanatory: a bare `nat` in a tool argument means the agent, and a
  model that drops the `@` addresses the wrong party. `user_notes` carries the
  distinction in `to_kind`/`from_kind`; the tool's error message must carry it
  in words.
* **`agents-list`'s result cap.** The tool's output is capped (~4000 chars) and
  its projection is a fixed size; one human line fits, and the projection
  should be revisited when a space can have several.

## What this does not do

* **No automatic delivery of a turn's response to the human.** The reply is the
  agent's `agents-send`, by design (above).
* **No reminders and no give-up on the human.** The banner is advisory; a human
  has no turn to wedge.
* **No cross-space addressing.** An address is resolved inside one space.
* **No prompt change for discovering the human.** `agents-list` carries the
  addresses; the system prompt is fixed and would go stale.
* **No change to the agent page.** `/space/:slug/agent/:name` keeps its
  meaning and its transcript; only its header text changes.
* **No change to how a note reaches an agent.** The inbox, the drain, the batch
  rule and the compaction interplay are untouched, except that a human's note
  is never merged into a peer batch.
* **No new transport.** Notes are already casts and inbox entries; a human
  target is a row and a broadcast.
* **No multi-user feed.** One feed is one human's view: the notes they are an
  end of, in the space's order. A space with several humans has several feeds
  over the same table, and a note between two of them is one row both feeds
  read.
