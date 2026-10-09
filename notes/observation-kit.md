# The observation kit — recording and reading a real session

`Nest.Timeline` writes a JSONL timeline of what a running space actually did,
and `mix nest.timeline` renders it as a digest. It exists because the messaging
redesign's interesting failures (a message that went nowhere, a reply that was
never owed or never answered, a turn that ended without a request) are only
visible in a real session — a test suite with a stubbed provider cannot produce
them.

This is a working tool, not a design document. The writer's contract is in
`lib/nest/timeline.ex`'s moduledoc, and the digest's shape in
`lib/nest/timeline/digest.ex`'s.

## Recording a session

Recording is **off by default**. Turn it on *before* the server starts:

```
NEST_TIMELINE=1 mix phx.server
```

`1`, `true` and `yes` all work. The equivalent config form is
`config :nest, timeline_enabled: true` (application config wins when it is set
at all; the environment variable is the fallback).

Two things to know before you start:

* **The switch is read at call time but must be set for the process that
  records.** A session is recorded by the *running server*, so exporting
  `NEST_TIMELINE=1` in a shell that never started `mix phx.server` records
  nothing. If a run directory is missing, check how the server was started.
* **One run directory per OS process.** The run id is captured once per BEAM,
  so a server restart starts a *new* run directory — one directory per session,
  and the newest one is what `mix nest.timeline` shows. Everything the kit knows
  about the inbox, the debts and the child graph is in-process, so a restart
  loses the state as well as starting a new file.

## Where it lands

```
notes/usage-runs/<run_id>/events.jsonl
```

* `<run_id>` is `<vm start: YYYYmmdd-HHMMSS>-<ospid>` — for example
  `20261009-134512-12345`. It is derived from the VM's start time, so it is
  stable for the whole session and two processes starting at once cannot
  disagree about it.
* The directory is created lazily on the first event, so a session that records
  nothing leaves nothing behind.
* `notes/usage-runs/` is gitignored (`.gitignore`), so a dump never shows up in
  a diff. Point it elsewhere with `config :nest, timeline_dir: "…"` if you want
  to keep a session.
* One JSON object per line, one line per event, appended. The runtime calls
  `Nest.Timeline.record(space_id, agent_name, type, payload)`; anything
  content-shaped goes through `Nest.Timeline.redact("args", args)`, which records
  a bounded head plus the size (see "What is *not* in the file" below).

A raw line looks like this:

```json
{"agent":"coordinator","args_bytes":21,"args_head":"rg -n \"defmodule\" lib","is_error":false,"mono":447,"name":"shell-cmd","result_bytes":2100,"space":7,"tool_call_id":"call-9","ts":"2026-10-09T17:52:54.733136Z","type":"tool","worker":"tool-1"}
```

(No `duration_ms`: nothing measures a per-call duration — the tool worker does
not, and the machine has no start stamp — so the digest prints no `ms` segment
at all; see "The event schema" below.)

## The event schema

Every line is a flat object with the common fields `ts` (ISO8601 UTC), `mono`
(milliseconds since this OS process started — the run's zero point), `space`,
`agent` and `type`, plus that type's payload:

| type | payload |
| --- | --- |
| `turn` | `event` (the machine event tag), `from` / `to` (each `{kind, phase}`), `iteration`, `max_iterations`, `message_indices` |
| `llm` | `message_index`, `iteration`, `model`, `projected_tokens`, `limit`, `reserve`, `remaining`, `outcome` |
| `tool` | `name`, `args_head`, `args_bytes`, `result_bytes`, `is_error`, `worker`, `tool_call_id` — no `duration_ms`: the worker does not measure per call and the machine has no start stamp |
| `inbox` | `action` (`enqueued` / `queued` / `delivered` / `drained` / `refused`), `from`, `kind`, `mode`, `bytes`, `count`, `disposition`. On a `drained` line `disposition` repeats `mode` (the drain has no sender to report a disposition for) |
| `debt` | `action` (`set` / `cleared` / `reminded` / `gave_up` / `give_up_refused`), `peer`, `reminders_used`, `how` |
| `status` | `payload` — the `chat:status` payload verbatim (it is small, and "what did the UI actually see" is the question the transparency rule makes central) |
| `notification` | `notification_type`, `message` |
| `error` | `message`, `source` (the `[Source: Module.fn/arity]` tag) |
| `compaction` | `limit`, `reserve`, `used`, `projected`, `carried`, `loop_count`, `archived_to_index`; `trigger` only on the commit line, where it is `"commit"` — the staged line has no honest value for it |
| `usage` | `input`, `output`, `cache_read`, `cache_write`, `total`; the child-usage line adds `name`, the child the cost came from |
| `child` | `action` (`spawned` / `completed` / `failed` / `terminated` / `archived` / `stopped`), `name`, and — on the spawn line only — `vocation`, `depth`, `model`, `clone_context`, `archive` |

Two shapes a line can take instead of its payload, both of them visible rather
than silent:

* `encode_error` — the payload could not be encoded (a pid or a tuple reached
  the writer). The common fields survive and the writer keeps going.
* `truncated: true` plus `line_bytes` — the line would have been over 8192
  bytes, so the payload was dropped and only its size recorded.

## Reading it

```
mix nest.timeline                                  # the newest run
mix nest.timeline --run notes/usage-runs/20261009-134512-12345
mix nest.timeline --space 7 --agent coordinator     # filter
```

`--space` and `--agent` are compared against the recorded values as strings, so
`--space 7` matches the integer `7`. A filter that matches nothing prints a zero
summary and no timeline. The task only reads files — it does not start the
application — so it works while the server is still running, and after it is
gone. With no runs at all it prints
`No runs found under notes/usage-runs/. Start the server with NEST_TIMELINE=1 to record one.`

```
Timeline digest — notes/usage-runs/20261009-134512-12345
events: 13
Summary
  spaces: 1   agents: 2
  turns: 1   llm requests: 1   tokens: in 120.0k out 4.2k cache r 80.0k w 1.2k
  tool calls: 1 (0 errors)
  inbox: enqueued 0 · queued 0 · delivered 1 · drained 0 · refused 0
  debts: set 1 · cleared 0 · reminded 0 · gave_up 1 · give_up_refused 0
  compactions: 1
  children: spawned 1 · completed 1 · failed 0 · terminated 0 · archived 0 · stopped 0
  notifications: 1   errors: 1
space 7 · agent coordinator  (12 events)
      0.44s  turn           idle/build → generating/build · chat_request · iter 1/25 · message_indices=[12]
      0.45s  inbox          delivered from alice kind query 84B count 1 · delivered
      0.45s  debt           set peer alice reminders 0 · delivered
      0.45s  llm            #12 iter 1 · 12345/200000 projected (reserve 16000, remaining 171655) · gpt-4o · sent
      0.45s  tool           shell-cmd args 21B result 2100B · tool-1 · call-9 · rg -n "defmodule" lib
      0.45s  child          spawned worker-1 (programmer, depth 1, gpt-4o) · archive
      0.45s  status         payload owedReplies=["alice"] pendingMessageCount=1 status=streaming
      0.45s  notification   max_iterations · Max tool iterations reached
      0.45s  error          Nest.Agents.Agent.Turn/1 · provider returned 502
      0.45s  compaction     reserve_exhausted · limit 200000 reserve 16000 used 190000 projected 205000 · carried 3 · loops 1 · archived→88
      0.45s  debt           gave_up peer alice reminders 1 · no_reminder
      0.45s  usage          in 120000 out 4200 cache r 80000 w 1200 · total 124200

space 7 · agent worker-1  (1 event)
      0.45s  child          completed worker-1 (-, depth 1, -) · archive
```

How to read a line: the stamp is `mono` in seconds since the run started; then
the event type; then the fields the digest knows how to render, followed by any
field it does not as `key=value` (so a field an emitter adds later still shows
up). `-` means the field was absent, and `?` in the stamp means the line had no
`mono` at all. The summary is computed over the *filtered* events, so `--agent`
narrows both halves. Unreadable lines are reported at the end by line number and
skipped, so one corrupt line never hides the rest:

```
Unreadable lines
  line 16: invalid JSON: unexpected byte at position 1: 0x6F ("o")
```

When the file itself cannot be read the digest says so in the same section
(`file: cannot read <path>: no such file or directory`) and prints a zero
summary — that is the ordinary "this run directory has no `events.jsonl`" case,
and it is reported rather than rendered as an empty session.

## What to look for

Start with the summary counters; then read the per-agent block. The failure
classes this kit exists for, and the events that answer them:

* **Did a queued message ever appear in neither the queue nor the transcript?**
  Follow the `inbox` events for one entry: `enqueued` / `queued` should be
  followed by `delivered` or `drained` for the same `from` and `count`, and the
  `status` payloads' `pendingMessageCount` should never drop to zero without one
  of those. A `refused` is the honest "it was never queued" case.
* **Did a debt get set and never cleared or given up?** A `debt` `set` for a
  `peer` should be followed by a `cleared` (a successful `agents-send`) or a
  `gave_up` for the same peer. A `reminded` with no `cleared` between it and the
  give-up means the one reminder did not land as a reply.
* **Did a give-up get refused?** A `debt` `give_up_refused` means the requester
  could not be told (broken status, full inbox, or gone); the same moment shows
  up as a `notification` and/or an `error`, which is where the reason is.
* **Did a turn end without an LLM call, or a request without a turn?** Compare
  the `turn` transitions into `idle` with the `llm` events' `iteration` and the
  `usage` totals. A turn that settled with no `llm` at all is the shape the
  settle-gate work is about; an `llm` with no enclosing `turn` transition means
  the transition funnel is missing a site.
* **How close did the projection get to the limit before a compaction?** The
  `llm` event's `projected_tokens` against `limit`, `reserve` and `remaining`,
  then the `compaction` event's own `projected` / `limit` / `reserve` and its
  `trigger`. Reading several of these in a row is how you tell "one huge tool
  result" from "a conversation that crept up".
* **Did a child get spawned and never terminate?** A `child` `spawned` for a
  `name` with no `completed` / `failed` / `terminated` / `archived` / `stopped`
  for that name — and, because a spawn's answer now arrives as a message, the
  matching `inbox` event is the other half of the same question.

## What is *not* in the file

The timeline is a diagnostic record, not a transcript, and the redaction policy
is deliberate:

* **Content-shaped values are a bounded head plus a size.** A tool's arguments
  are recorded as `args_head` (at most 200 bytes, ending in `…` when cut) and
  `args_bytes` (the full size). The same goes for anything else an emitter marks
  as content. You get the beginning and the size, never the whole thing.
* **Never a whole transcript, a whole tool result or a whole message.** If the
  interesting part is beyond the head, the size tells you it is there and the
  transcript or the scratch file is where to look.
* **A line over 8192 bytes is replaced by a stub** (`truncated: true` plus
  `line_bytes`), so one careless event cannot fill the directory.
* Heads are always valid UTF-8 (a partial character at the cut is dropped and a
  non-UTF-8 tool result is sanitised), so a dump is always readable text.
* A failed write logs one warning and then disables the writer for that
  directory, and a payload that cannot be encoded becomes a stub. The kit cannot
  break a turn, and that is why you will sometimes see a warning instead of an
  event.

## Its limits

* **Recording a session is not part of `mix test`.** It needs a real provider
  and a network, and it is slow, so it is deliberately outside the suite; the
  kit's own unit tests (`test/nest/timeline_test.exs`) cover the writer, the
  redaction and the digest, and a real session is the evidence.
* **A disabled writer costs at most two configuration lookups per event** — app
  config, then the environment variable — and nothing else: no encoding, no file
  system, no directory created.
* **It is per OS process.** A BEAM restart starts a new run directory and the
  in-process state it was describing (inbox, debts, children) is gone with the
  old one.
* **A run is only as complete as the emitters.** A state change nobody records
  is invisible here, so a gap in the digest is a missing emitter, not necessarily
  a missing event.
