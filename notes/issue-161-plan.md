# Plan: #161 — deliver a queued backgrounded result at the boundary

**Provenance.** Written from the transition table at nest `7a66195`, plus a trace test
(`MachineBackgroundingTest`, "a queued backgrounded result (#161)") that failed against the
pre-fix code. Every `path:line` anchor is from that HEAD.

## Goal

A backgrounded batch's result is queued as a `:runtime` entry. It must be delivered at a
natural decision point, and it must **never** be delivered by backgrounding a batch that was
about to run. Invariant:

> When a request is dispatched, every `:runtime` notice that had already arrived is in the
> context.

## The mechanism this fixes

Two decisions could deliver a queued notice, and neither could tell it from a message:

- `Machine.Boundary.drain?/1` (`lib/nest/agents/agent/machine/boundary.ex:61`) gated on
  `deliverable_tail?/1`, which accepts only a `:tool` or `:assistant` tail. A backgrounding
  delivery leaves the tail on the delivered **`user`** row (`[synthetic result, ack, message]`),
  so the boundary refused.
- `Machine.Backgrounding.deferred_actions/1` (`machine/backgrounding.ex:137`) fired on
  `inbox_count > 0` at a batch's `:worker_started`, whatever was queued.

So the only path that could deliver a notice was the deferral — by backgrounding the *next*
batch at birth. Each backgrounded result therefore cost: one synthetic result + one
acknowledgement appended, one batch stolen, and one extra model round trip, with the model
deciding each tool call without the previous call's result. It ended only when the agent
stopped asking for tools.

## Decisions

| # | decision | rationale |
|---|---|---|
| D1 | A queued `:runtime` notice is deliverable on **any** tail, including the `user` row a backgrounding delivery leaves | the notice is not a turn's request. The append is the live bridge `Repair.classify_live/2` already owns, so the cost is that bridge's acknowledgement instead of a stolen batch. |
| D2 | A queued `:runtime` notice **never arms the deferral** | preempting a batch to make a landing place for the runtime's own bookkeeping is what produced the permanent one-behind. It waits for the boundary, which D1 makes able to carry it. |
| D3 | The context carries `inbox_head_kind` (`Turn.build_ctx/2`) | the machine is pure and saw only `inbox_count`; both decisions need to know *what* is queued. A `nil` kind — every hand-built fixture, every producer predating the field — reads as "not a notice", so the rule is narrow and nothing else changes. |
| D4 | Human messages and peer traffic still preempt | D1/D2 narrow #36's D1 to "a notice does not preempt". A human waiting on a long tool call is still delivered immediately. |

### Rejected

- **Coalescing consecutive human messages** (relaxing #31 decision 8). It explains a delivery
  per human message, not the lag; it was the first diagnosis and it was wrong.
- **Not preempting at all** — letting the batch finish and delivering at its boundary. That
  reinstates #103's problem: a message arriving before the batch exists waits for the whole
  batch, up to a 300 s `shell-wait`.
- **A machine timer.** #36 D4 forbids one, and a threshold on "how long is too long" is the
  same smell as a timeout used as a barrier.

## What it looks like

Before (each tool call after the first is backgrounded at birth to deliver the previous
notice, and the model never sees a result before choosing the next call):

```
assistant  tool_use A
tool       A: "backgrounded"          ← A stolen for the human message
assistant  "Understood. The call is running in the background…"
user       H
assistant  tool_use B
tool       B: "backgrounded"          ← B stolen for A's notice
assistant  "Understood. …"            ← second ack
user       "… A finished …"
assistant  tool_use C
```

After (one backgrounding, then every call runs to completion and the notice rides the next
request):

```
assistant  tool_use A
tool       A: "backgrounded"
assistant  "Understood. …"
user       H
assistant  tool_use B
tool       B: "done, real output"
user       "… A finished …"           ← at B's boundary, before the next request
assistant  tool_use C                 ← chosen knowing A's and B's results
```

## Verification

- `MachineBackgroundingTest` "a queued backgrounded result (#161)": the boundary delivers on
  the user tail; the deferral does not fire for a notice; a queued human message still does.
- `CloneAgentFlowTest` pinned the old shape — the notice got a turn of its own, one extra
  request per backgrounded result. It now asserts the notice rides the request the delivered
  answer started.
- `mix precommit`: 2395 tests, 0 failures.

## Left undone, deliberately

`Turn.Backgrounded.delivery_actions/2` still drains only on `:idle`. With D1+D2 the boundary
now covers every other phase, so that clause remains correct as the wake-up for an agent that
has no turn left to reach a boundary.
