# Result admission — one rule, one place

## The rule

Every result that would enter the live message list is admitted by
`Nest.Agents.Agent.ResultPolicy`:

```
budget    = context_limit - compaction reserve - size(messages) - already admitted
requested = the model's `max_result_tokens`, else the tool's default
inline    = min(requested, budget)

size(content) <= inline -> inline whole
otherwise               -> on_over/1: :file   -> write it, inline a pointer + preview
                                    :refuse -> a size-hint error
```

There is no share of the window and no second predicate. `requested` is what
the model asked for (8_000 for most tools, 32_000 for `file-read`) and the only
ceiling on it is the budget actually left. A model that asks for more than the
budget gets the budget; a model that asks for nothing gets the default.

`budget` is decremented by each admitted result, so a batch shares one
allowance and neither a result nor a batch can exceed the window. That is why
there is no separate "does it still fit the batch" check.

## `on_over`

- **`:file`** — every tool whose output exists nowhere else, and every message.
  The content is written to the agent's scratch dir and replaced by:

  ```
  Output of shell-cmd (640017 tokens) saved to /tmp/agent/exec-abc.txt.

  Exit code 2:
  JOURNAL.md:22332:step is the acceptance run …
  ```

  The pointer names the tool and the size; the preview is a **fixed** ~200
  tokens of whole lines. Neither repeats the call's arguments — they are in the
  `tool_use` part immediately before it — and neither depends on the budget,
  which is what lets `ProjectedSize` price a substitute exactly.
  `Overflow.substitute_size/0` and `Overflow.substitute/5` describe the same
  block, one function, so they cannot drift.

- **`:refuse`** — `file-read` only. The content is already at the path the call
  named, so a second copy would be redundant and the model can narrow the read
  (`file-inspect`, a line range, `grep`). The error names the size and the
  limit. `ProjectedSize.read_file_projection/2` clamps its projection to that
  limit, because the tool is structurally unable to produce more inline; without
  the clamp a batch is refused for a call guaranteed to return one line, and
  that refusal cannot be cleared by compaction (it is a property of the file,
  not the transcript).

## No uncapped path

The admission runs for every result whatever its kind — a success, an error, a
cancellation and a wait are the same content question. Before it did, the
`is_error`/`:cancelled` arm sized a result and kept it inline without checking
either the limit or the batch budget; a `grep` that exited 2 with 1.8 MB of
output produced a 1.42M-token request against a 1.05M window.

A write that fails is its own error (`ResultPolicy.offload_failure/1`), never a
quiet inline fallback: the send gate is a never-happen tripwire, not a place to
absorb an oversized result.

## Messages

Messages share the rule with a different `requested`: the configured
`max-async-message-tokens` (`Config.configured_async_message_max_tokens/0`,
default 8_000). That cap is intrinsic — how much one body may carry — so a
message over it is filed rather than allowed to force a compaction. A message
*under* it is delivered whole, and the conversation being full is what the fit
decision and a compaction are for.

`Inbox.Render.combine_and_offload/2` (a drained batch) and
`Inbox.Render.admit_single/2` (a single message, including a human's) are the
two call sites. A batch that cannot be filed leaves its entries queued and
surfaces a `chat:error`.

## The send gate

`Machine.Transitions` checks `Budget.fits?/2` before every request and compacts
instead of sending. It is a tripwire and should never fire: `start_chat/3`, the
batch preflight and `ResultPolicy` all keep the list inside `L - C` first. It
exists so a conversation that is somehow over budget cannot reach the provider,
because the provider's 400 is a bug report rather than a recovery path.

## What this replaced

- `floor(usable * 0.80)` as the default inline size (`CapCalculator`), and the
  model being able to only *lower* it. The 80% share was a ceiling nobody chose;
  the model asking is the only reason to go large.
- `keep_full?/3` and the running-total pass: the budget is the running total.
- The `substitute/5` head, whose size came from the header (which echoed the
  whole shell command).
- The `:error`/`:cancelled` arm's exemption.
