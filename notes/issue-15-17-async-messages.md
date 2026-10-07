# Issues #15 + #17 — async agent messaging

Branch `async-messages`, off `main` (`b726045`). Two related issues, one theme:
an agent should not sit blocked waiting for a peer, and a message should reach
its target at the next safe point instead of at idle.

## #15 — deliver messages sooner

Today the inbox is drained only at turn end / idle (`transitions.ex`:
`{:drain_inbox}` in the terminal and idle paths; `machine/response.ex:102`,
`:122`, `:138`, `:146`; `machine/compaction.ex:133`). So an `agents-send` — or a
human message sent through the channel — waits for the target to go idle, even
when the target is about to start a whole new LLM request.

Goal: deliver at **safe points inside a turn** — after the current API response
or tool execution completes, before starting the next one — and when messages
are waiting, prefer starting a new turn with them over continuing the current
one. The human-user path goes through the same inbox
(`Nest.Agents.Agent.deliver_message/3`, `agent.ex:402`), so it comes along.

Hard constraints:

- Never interrupt an in-flight API request or a running tool. "Pre-empt" means
  *at the boundary*, never mid-call.
- Never lose a message. The machine already has a `{:restore_inbox, entries}`
  path for the case where drained entries cannot be used (`transitions.ex:414`).
- The drained entries must land in the *next* turn as the model sees them, in
  order, without duplicating the current turn's work.

## #17 — async modes, plus `agents-wait`

1. **`agents-wait` (new tool).** Takes a list of agent names, or `[]` for every
   other agent in the workspace.
   - Returns immediately if all of them are idle.
   - Otherwise returns when the *first* one becomes idle, with that agent's name
     and its stop-message content.
   - Bounded by an explicit wall-clock `timeout` argument. Per the #20 lesson
     the budget must be elapsed time, never a message count, and a timeout is a
     normal result, not an error.
2. **`agents-spawn` / `agents-query` gain an async mode.** The call returns
   immediately; the child's final message is delivered to the parent's inbox
   with a prefix note identifying it as an `agents-spawn` / `agents-query`
   result. Reuse the `agents-send` delivery path.

## Tasks

| task | scope | risk |
| --- | --- | --- |
| **A** | `agents-wait` tool: spec in `lib/nest/tools.ex`, execution + the wait, tests | low — additive |
| **B** | async modes for `agents-spawn` / `agents-query` | medium — reuses the send path |
| **C** | #15's boundary delivery in the machine | **highest** — design + review before code |

**C lives on its own branch** (`boundary-delivery`, design in
`notes/issue-15-boundary-delivery.md`) because #15 and #17 are separate
issues. This branch is #17 only: A + B.

### Task B spec (async modes)

Both tools gain `async: boolean` (default `false`). With `async: true` the
tool call returns immediately with a confirmation result and the
outcome is delivered to the *calling* agent's own inbox, so it lands as
a normal inbox message — at the parent's next turn boundary once #15
lands, and at its turn end before that.

Delivery is `Agent.deliver_message/3` (`{:deliver_async, sender,
content}` → `Inbox.handle_delivery/3`), which already queues for a busy
target and starts a turn for an idle one. The content carries a prefix
note naming the call that produced it, e.g.

    [agents-spawn result for "worker-1"]
    <the child's final text>

**Mechanism.** The wait must not run in the calling agent's process (the
turn worker is the blocking surface), so an async call starts a
supervised waiter under `Nest.Agents.TaskSupervisor` and the tool worker
returns. Concretely:

- `agents-spawn` async: the tool worker starts the waiter, then does the
  `{:spawn_agent_request, waiter_pid, opts}` call **synchronously** so a
  bad spawn (unknown vocation, depth cap) still comes back as an
  immediate error tool result the model can fix; on success the waiter
  owns the `{:spawn_agent_result, name, response}` /
  `{:spawn_agent_error, name, reason}` receive and delivers the note +
  text (or the failure) to the parent's inbox. On a spawn error the
  worker must abandon the waiter so it cannot wait forever.
- `agents-query` async: the waiter does exactly what the blocking path
  does (`query_peer/4`: subscribe, `Agents.chat/4`, wait for idle, read
  the reply) and delivers the same success/failure text the blocking
  path would have returned as a tool result.

Both waits keep the existing bounded wall-clock `timeout` argument; a
timeout is a normal result, delivered as a message, never a crash.

**Waiter lifecycle.** A waiter must die quietly when its parent is gone
(monitor the parent; no log noise, no crash report) and must be bounded
by its timeout. It must not outlive a test and print to the console.

The tool descriptions and the `tools.ex` stubs must state the async
behaviour, and `agents-wait` (A) is the natural companion: "spawn async,
then wait for it".

## Acceptance

- New tools are declared in `sub_agent_tool_function/1` **and** listed in the
  tool-name list, with full specs (`lib/nest/tools.ex:57-80`).
- `agents-wait` returns immediately when everything is idle, and on the first
  idle otherwise; both paths plus the timeout path are tested.
- Tests sync on state, never on sleeps; any fence stays at or under 500ms.
- Async spawn/query never block the parent's turn and deliver exactly one
  result message, with the note.
- #15: a message sent mid-turn is delivered at the next boundary, no message is
  lost, and the ordering the model sees is unchanged.
