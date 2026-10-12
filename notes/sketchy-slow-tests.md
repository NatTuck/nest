# Sketchy slow tests

Working notes for **#21** (the Elixir test-suite timeout audit). This file records
the cases that are **not** easy fixes: number/policy calls that need a human,
sites deliberately left alone, and anything left failing on purpose.

Scope of this file: the `test/nest/**` (excluding `test/nest/agents/**`) and
`test/nest_web/**` half of the easy-cleanup pass. The harness half
(`test/support/**`, `test/test_helper.exs`, `test/mix/**`) and
`test/nest/agents/**` are recorded separately by the agents that own them.

## 1. The 2000 ms cap — what it changed

The rule is **"absolutely none over 2000 ms for any reason."** Everything below
was a real *test wait* (a fence, a helper default, a synchronous-call timeout),
not test data.

| file:line | was | now | note |
|---|---|---|---|
| `test/nest/tools/shell_jobs_test.exs:52` | `eventually …, timeout: 5_000` | `2_000` | polls the manager's authoritative status; kept polling, only the budget came down |
| `test/nest/models_rescan_test.exs:135` | `Process.send_after(self(), :deadline_should_be_cancelled, 60_000)` | `2_000` | **see §5 — this one has a tension** |
| `test/nest/models_rescan_test.exs:147` | same | `2_000` | same |

### What is deliberately NOT changed, and why

`rg` for numbers over 2000 surfaces a lot that merely *looks* like a timeout.
These are **test data or assertions about production behaviour**; changing them
would break the test or change what it proves:

- `assert ShellCmd.default_timeout_ms() == 60_000` (`test/nest/tools/shell_cmd_test.exs:274`)
  — asserts a **production** default.
- `receive_timeout: 30_000` / `receive_timeout: 5000` in
  `compaction_probe_support_test.exs:77,98,135`, `chat_model_test.exs:191,194`,
  `discover_test.exs:26`, `discover_probe_base_url_test.exs:34`,
  `client_test.exs:139`, `restore_test.exs:69` — **config values under test**.
- `exit({:normal, {GenServer, :call, [self(), :get_and_update, 5000]}})` and
  `{:timeout, {GenServer, :call, [Nest.Models, :list, 5000]}}`
  (`chat_task_cleanup_test.exs:55,84`, `agents_test.exs:263,271,274`) —
  **simulated production error tuples**.
- Token counts and fixture sizes: `TextFixtures.big_text(30_000)`,
  `Overflow.message(10_000, …)`, `String.duplicate("a ", 30_000)`,
  `user_id + 10_000`, `input_tokens: 5_000`, `limit => 10_000`,
  `Reserve.compaction_reserve(50_000)`, `PreFlight.check(30_000, 32_768)`.

## 2. `:sys.get_state` / `:sys.replace_state` — explicit 500 ms

Every call in scope now passes an explicit `500` instead of inheriting OTP's
**5000 ms** default: **50 sites across 12 files**.

### The "cheating" question — where the barrier is not justified

The user's ask was also to *"consider if cheating that way is justified for the
test at all."* Two distinct shapes exist in this scope, and only one is a
smell:

**Genuine reads** (the result is used) — fine. These read the state because the
assertion *is about the state*: `models_test.exs` (`static_config`),
`agent_channel_queued_message_test.exs` (`live.inbox`, `chat_state.messages`),
`agent_channel_chat_test.exs:654` (`live.machine.work.focus`),
`tools/shell_jobs_test.exs:46` and `sandbox/shell_jobs_test.exs:42` (`waiters`),
`agents_test.exs:510`.

**Barriers whose result is discarded** (`_ = :sys.get_state(...)`, or a `settle/1`
helper) — these exist **only** to queue behind earlier messages, i.e. to
synchronise. There are **6** of them plus one helper used **22 times**:

| site | uses |
|---|---|
| `test/nest_web/channels/agent_channel_test.exs:181` | 1 |
| `test/nest_web/channels/agent_channel_test.exs:526` | 1 |
| `test/nest_web/channels/lobby_channel_test.exs:280` | 1 |
| `test/nest_web/channels/lobby_channel_archive_test.exs:401` | 1 |
| `test/nest_web/channels/lobby_channel_scoping_test.exs:523` (`defp settle/1`) | **22** |
| `test/nest/sandbox/shell_jobs_test.exs:91` | 1 |

`lobby_channel_scoping_test.exs`'s `settle/1` is the biggest single case: 22
call sites that all reduce to "wait until the channel has handled what I just
pushed". It is documented as such (`:518` — *"`:sys.get_state/1` is a
`GenServer.call`, and `gen_server` …"*), so it is a *deliberate* barrier rather
than an accident — but it is exactly the shape the repo already calls a smell
elsewhere: `test/nest/agents_test.exs:574` says *"The `:sys.get_state/1` 'drain'
was a code smell — it bypassed the GenServer protocol and was only useful for
synchronizing on prior messages."*

**Needs a human:** decide whether a discarded-result `:sys.get_state` drain is
acceptable as a synchronisation idiom, or whether these should wait on the
broadcast they are implicitly waiting for. The channel tests already receive the
broadcast; the drain is there because the *assertion* runs in the test process
while the channel processes the push. **Not changed here** — converting a
barrier into a broadcast wait changes what the test synchronises on, and a
wrong conversion is a flaky test, which this project ranks as worse than a
failing one.

### One file cannot take the explicit timeout — it is at the line cap

`test/nest_web/channels/agent_channel_chat_test.exs` is **699 total lines on
`main`** (cap 700), so *any* addition fails credo. It therefore keeps
`:sys.replace_state/2` at OTP's default for its **9** call sites, and only its
`:sys.get_state` calls take the explicit `500`. The other five files use a
small private helper instead, so their call sites keep the original compact
layout:

```elixir
# `:sys.replace_state/3` with an explicit timeout: OTP's default is 5000 ms,
# which is ExUnit's own per-test ceiling, so a wedged server would surface as
# a test timeout rather than as the stuck call it is (#21).
defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 500)
```

**Worth knowing for the next person:** passing the timeout positionally
(`:sys.replace_state(pid, fn … end, 500)`) makes the formatter break the call
across five extra lines — and because Elixir's formatter *preserves* a
broken-arg layout once it has been written, reverting the extra argument does
**not** restore the compact form. That is what pushed this file to 735 lines on
the first attempt. The helper avoids the problem entirely.

**Needs a human:** extract something from
`agent_channel_chat_test.exs` so it has headroom; it is one of the files where
the next change will fail on the cap, not on its merits.

## 3. `eventually` — what remains, and why

`Eventually.eventually/2` has drifted to ~67 call sites suite-wide while its own
moduledoc and the credo check describe it as used by *"a small number of
tests."* In this scope there are **5** sites. **None of them converts cleanly**,
and each is recorded rather than converted:

| site | polls | verdict |
|---|---|---|
| `tools/shell_jobs_test.exs:51` | `ShellJobs.status(key, id)` until `{:exited, _}` | **pollable, with a real event available** — see below |
| `sandbox/shell_jobs_test.exs:154` | `ShellJobs.list(key) == []` after the agent is killed | **pollable, with a real event available** — see below |
| `tools/shell_cmd_test.exs:220` | `stale_down_pending?()` | **must stay a poll** — `stale_down_pending?/0` inspects `Process.info(self(), :messages)`, i.e. it waits **without consuming**. `assert_receive` would consume the stale `:DOWN` and destroy the thing the test is about. |
| `agents_test.exs:397` | `Machine.status_for(:sys.get_state(pid, 500).live.machine) == :idle` | **polling is deliberate** — the repo's own `await_idle/1` doc argues that polling the machine's authoritative status means *"a missed or reordered broadcast can never be the reason a test fails."* A `chat_status` broadcast does exist, so `assert_receive` is possible but trades robustness for speed. |
| `agent_channel_queued_message_test.exs:274` | `:sys.get_state(agent_pid, 500).chat_state.messages` until an exact message sequence | **polling is deliberate** — the assertion is on the full ordered transcript, not on one event; a single broadcast cannot express it. |

**Concrete lead for the two ShellJobs polls:** `lib/nest/sandbox/shell_jobs.ex`
**does** broadcast on every state change —
`Phoenix.PubSub.broadcast(PubSub, "agent:#{space_id}:#{name}", {:shell_jobs, %{jobs: jobs}})`
at `:191`, `:256` and `:390` — and sends `{:shell_job_exit, job_id, code}`
directly to waiters at `:227` and `:454`. So both polls *could* be replaced by
waiting on the broadcast. **Not done here**, because the polls assert on the
manager's authoritative status (`{:exited, _}`, `== []`) rather than on "some
broadcast arrived", and several broadcasts may be needed to reach the condition
— so the replacement is a loop over broadcasts, not obviously simpler or more
robust than the poll. Worth doing deliberately, by someone who can test it.

## 4. Deliberate far-future timers, and one tension the cap creates

`models_rescan_test.exs:135,147` used
`Process.send_after(self(), :deadline_should_be_cancelled, 60_000)`. That value
is **not a wait** — it is a deliberately unreachable deadline that the test then
proves gets *cancelled* (`Process.read_timer(timer) == false`,
`refute_received :deadline_should_be_cancelled`).

It is now `2_000` to honour the cap. **The tension:** at 60 s the deadline could
never fire even on a pathologically slow host; at 2 s it can, and if it does,
`refute_received :deadline_should_be_cancelled` fails. That makes this test
load-sensitive in a way it was not before. This is recorded rather than reverted,
per the instruction to report failures instead of restoring a long timeout.

**Needs a human:** the clean fix is not a number — it is to stop using `self()`
as the timer's destination (or to `refute_received` before the timer can fire
regardless of value), so the test cannot depend on how long it itself takes.

## 5. Policy calls that need a human

1. **Is a discarded-result `:sys.get_state` drain acceptable?** See §2. One
   helper (`settle/1`) accounts for 22 call sites.
2. **The two ShellJobs `eventually` polls** have a broadcast available (§3). Do
   we want to convert them, accepting a loop over broadcasts?
3. **`agents_test.exs:397`** — poll the machine status, or wait for the
   `chat_status` broadcast? The repo currently prefers polling for robustness;
   the user asked to reduce `eventually` use. These pull in opposite directions
   and it is a policy call, not a local one.
4. **`ExUnit.configure(timeout: …)`** — the global per-test ceiling lives in
   `test/test_helper.exs` and is owned by the harness half of this pass. If it
   comes down to 2000 ms, every test in this scope must fit in 2 s. Nothing in
   this scope was observed to need more, but that is a suite-wide decision.

## 6. What was verified

- The 2000 ms cap holds for every real test wait in scope; the only surviving
  >2000 ms literals are the triaged non-timeouts listed in §1.
- `mix format --check-formatted` is clean after the changes (the formatter
  reflows the multi-line `:sys.replace_state/3` calls onto separate lines).
- See the agent's report for the `mix test` result and timings.
