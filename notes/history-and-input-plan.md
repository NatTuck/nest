# Plan: the recall list and the composer

Three requirements, taken together because they are one surface: the input box
and what Ctrl/Cmd+Up walks through.

1. History cycles through what the user actually **typed**.
2. The input boxes are React-controlled through the store, so a half-typed
   message survives leaving the page — and does not follow the reader to another
   agent or space.
3. Cycling history must not change the mode. The mode is the user's choice.

## D1 — `:composed` vs `:synthesized` (the marker)

`human?: true` did two jobs at once, and only one of them was ever wanted for
recall:

- the **header attribution** — the row reads "user @nat" — which all three send
  sites need;
- the **recall marker** — `origin: "human"` — which only the composer's send
  should earn.

Three sites passed the flag: the composer's `chat:message`, and the pane's
`deliver_explain` / `deliver_answers`, which are the human's words produced by
the *UI* and which nobody wants to recall. Clearing the flag on those two would
have fixed recall and broken the header (`Address.parse("nat")` is
`{:agent, "nat"}`, so the row would have read "agent nat").

So the boolean became a source, threaded from the call site to the entry:

| source | who | header | recallable |
|---|---|---|---|
| `:composed` | the composer's `chat:message` | user @name | **yes** |
| `:synthesized` | the pane's answer and explain deliveries | user @name | no |
| `false` | an `agents-spawn` `query` kickoff | — | no |

`Nest.Messages.User.source_metadata/1` is the one definition, used by both the
idle path (`ChatPipeline`) and the drained path (`MessageList.origin_metadata/1`),
and it **raises** on an unrecognised value: a future call site passing a bare
`true` fails loudly instead of silently dropping a prompt from recall.

Both markers reach the client (`origin`, `composed`), and both filter the
projection: `agent_channel_history.ex` asks for `origin: "human", composed:
"true"` on the `role: "user"` page, so the pane's rows cannot eat the 50-row
budget either. `chatHistory.js` requires the same pair.

Rows persisted before this change carry `origin` and no `composed`, so old
prompts leave the recall list — the same consequence the file already documents
for rows that predate the marker. Nothing is deleted from the transcript.

## D2 — drafts belong to what is being written to

The value lived in `useState` inside the page. Two consequences, both real:
`/space/X/agent/A` → `/space/X/agent/B` keeps `ChatPage` mounted (same route, new
param), so B's composer showed A's draft; and navigating away unmounted the page,
so the draft was gone on return.

`store/slices/composer.js` holds `drafts`, keyed by agent name or
`spaceDraftKey(spaceId)`. The pages read and write through it and clear on send.
In memory only — "leaving and returning" needs no persistence, and localStorage
is used for nothing but the auth token today.

## D3 — history navigation is a text operation

`onModeRestore` is gone from `ChatInput`, `ChatComposer` and both call sites. An
entry still records the mode it was sent under, but only so `stripHeader` can
remove the `[mode: X]\n` prefix and hand back what the bubble showed.

## Verification

- `agent_chat_mode_test.exs` pins all three sources' metadata;
  `agent_channel_pane_test.exs` already pins that a delivered answer reads
  `[From user @<name>` — which is what proves the header survived.
- `ChatPage.test.jsx` and `SpaceFeed.test.jsx` each pin restore-on-return and
  no-carry-across.
- `ChatInput.test.jsx` pins that walking the history never calls `onModeChange`.
- `chatHistory.test.js` pins that a synthesized row (`origin` without `composed`)
  is excluded, and that a composed one is included.
