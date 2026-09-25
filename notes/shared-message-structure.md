# Shared Message Structure (Canonical)

**This document is the source of truth for how agent messages are persisted.**
If code, a comment, or another note disagrees with it, that other source is
wrong. Do not edit this document to match the code; fix the code (or the other
note).

## The rule: one write, shared on clone

> Every message row is written to the database **exactly once** and is owned by
> exactly one agent (`messages.agent_id`). A clone **shares** its ancestors'
> rows; it never copies them. The full conversation for an agent is reconstructed
> by walking the `parent_id` chain.

A clone (`agents-spawn` with `clone_context: true`) shares the ancestor's rows
`[0 .. F-1]`, where `F` is the clone's first own `message_index` (the stored
`agents.fork_message_index`). The clone's own rows begin at `F` and continue
upward. It may add messages freely; the shared prefix is immutable and is never
duplicated.

## Fork semantics (Unix `fork/2`)

A clone is a `fork`: it shares the ancestor's sequence *including the real
trailing `agents-spawn` assistant `tool_use`*, and the fork returns a different
value in each process. The parent's next row is its own `tool_result`
("subagent spawned"); the clone's first own row is its own `tool_result` for the
**same `tool_use` id** ("you are now the delegate"), followed by an assistant
acknowledgement. The clone does **not** drop or re-synthesize the shared call.

## Worked example

```
Root R owns:   0   1   2   3   4   5           (next_message_index = 6)
               └ R:5 is the assistant[agents-spawn id=call_X]
Clone C of R:  shares 0..5, owns 6 7            (F_C = 6)
               └ C:6 = tool[call_X, "you are the clone"], C:7 = assistant[ack]

full(R) = R:0..5 ++ R:6 (R's own tool_result for call_X — not shared)
full(C) = (R:0..5) ++ C:6..7
```

If root `R` later writes its own row at index 6, `full(R)` gains it; `full(C)`
is unaffected because `before(full(R), F_C=6)` excludes index 6. Rows are
scoped by `agent_id`, so `R:6` and `C:6` are different rows.

## Definitions

- `own(A)` — rows where `messages.agent_id = A.id`.
- `F_A` — the first own `message_index` of `A`, i.e.
  `min(message_index for own(A))`. It is stored explicitly as
  `agents.fork_message_index` so fresh-vs-clone is unambiguous even
  before a clone has written its own rows. For a root or a fresh
  child this is `0` (and the column is `NULL`); for a detached clone
  it is `NULL` (see below).
- `before(list, k)` — the elements of `list` whose `message_index < k`.

## Resolver

```
full(A) = (A.fork_message_index ? before(full(parent(A)), F_A) : []) ++ own(A)
```

Resolve recursively up the `parent_id` chain. Depth is bounded by
`max_depth`, so this is a short walk. `fork_message_index = NULL` means "no
shared prefix": a root, a fresh child, or a detached clone.

`fork_message_index` is set to the parent's `next_message_index` at spawn, which
is exactly the index of the clone's first own row (the `tool_result`).

## Invariants

- **D1** One write, one owner. No duplicated message rows.
- **D2** Clones share `[0..F-1]`; they never insert copies of an ancestor's
  rows.
- **D3** `F_A` is the clone's first own `message_index`.
- **D4** A fresh child (`clone_context: false`) owns from index 0 and shares
  nothing.
- **D5** A clone never writes a system row at index 0. Index 0 belongs to the
  root ancestor and is inherited verbatim. The clone's identity and depth are
  stated by the fork return value it owns (the `tool_result` for the shared
  `agents-spawn` call) and its assistant ack.
- **D6** The resolver above is the only correct way to obtain a full sequence.
- **D7** `(agent_id, message_index)` is unique. Parent and clone may hold
  different rows at the same index; that is expected.
- **D8** The live path only appends. Only the offline repair tool
  (`notes/enforce-mesages-seq-invariants.md`) may rewrite/renumber rows.
- **D9** A clone **detaches** from its shared prefix at its first compaction:
  the prefix has been summarized away, so `fork_message_index` is cleared to
  `NULL` and the clone's own rows become its full sequence. Detach never
  renumbers rows (D8): the own rows keep their indices and the post-compaction
  active list starts with the rebuilt system.

## Fresh children vs clones vs detached

All have `parent_id` set (the tree is unified for lifecycle, usage, and the
sidebar). They differ in `fork_message_index`:

- Fresh child: owns its own system row at index 0, `fork_message_index = NULL`,
  shares nothing.
- Clone: no own system row, `fork_message_index > 0`, shares the ancestor prefix
  below it.
- Detached clone: no shared prefix anymore, `fork_message_index = NULL`; its own
  rows (which may start above 0) are its full sequence and the post-compaction
  active list begins with a rebuilt system row.

## Non-goals / explicitly wrong

- **Wrong:** cloning as a copy. Any statement that a clone "receives a copy of
  the parent's messages", "copies the conversation history", or persists via
  `INSERT INTO messages SELECT ... WHERE agent_id = parent_id` is incorrect.
- **Wrong:** dropping the parent's `agents-spawn` assistant and synthesizing a
  fresh spawn call for the child. The child shares the real call and answers it
  with its own "you are the clone" result (Unix-fork return value).
- **Wrong:** a clone writing its own system row at index 0 (it would shadow the
  root's shared system row).
- **Wrong:** loading a clone by `agent_id` alone and treating that as the full
  sequence; it must resolve the shared prefix through `parent_id`.

## Where this is enforced

See `notes/enforce-mesages-seq-invariants.md` for the append-time guard,
preflight rule list, and offline repair tool.
