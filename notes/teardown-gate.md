# The teardown gate's stop bound

`Nest.Agents.AgentTestLifecycle` stops every agent a test owns when the test body
ends, and raises if that did not leave zero agents behind. This note is the
record behind its stop bound (`@stop_ms`) and the burner probe that measured it.

## What the bound is for

The mandatory invariant is **"a test may not complete until its agent is already
idle"**. That is a statement about the agent, so it is asserted from *state*:
`stop_test_agents/0` asks every owned agent for its own status, in its own
process, before anything is stopped, and an agent that answers with
`[:streaming, :executing_tools, :compacting]` is a violation. No clock takes part
in that decision.

The stop that follows answers a weaker question — did the process die at all —
and `@stop_ms` bounds *that*. It is a liveness bound, not a measurement of the
agent.

## The defect it replaced

`@stop_ms` used to be 10 ms, on the stated premise that a compliant test leaves
its agent parked in its receive loop, so the handshake is microseconds and a
tight bound is therefore a detector rather than headroom. The premise is false:
`Agent.terminate/2` ends with `cleanup_tmp/2` -> `TmpSpace.cleanup/2` ->
`File.rm_rf/1`, which is synchronous filesystem work — a handful of round trips
through the global file server — **inside the window the bound measures**.

The stacktrace of every agent that crossed the bound says where it was — an
agent that is *stopping*, having answered `:idle` to the status question:

```
[status: :waiting, message_queue_len: 0,
 current_function: {:gen, :do_call, 4},
 current_stacktrace: [{:gen, :do_call, 4}, {:gen_server, :call, 3},
                      {:file, :call, 2}, {File, :do_rm_rf, 3},
                      {Nest.Agents.Agent.TmpSpace, :cleanup, 2},
                      {Nest.Agents.Agent, :terminate, 2}, ...]]
```

A stacktrace is a location, not a cause, so the cost was attributed by
measurement rather than by reading the frame. Under 32 BEAM burners on a
32-logical-CPU host, with agents that had all answered `:idle`:

| what | loaded | idle |
| --- | --- | --- |
| one `ClientAPI.get_status/2` round trip | 117 us | 1 - 9 us |
| `File.rm_rf/1` of an empty directory | ~9 ms | 14 - 68 us |
| `File.rm_rf/1` of a 100-entry directory | 332 - 597 ms | 1.2 - 1.4 ms |
| the stop handshake, 12 idle agents | 8.5 - 9.1 ms | 25 - 110 us |

So it *is* the file work — the empty directory's `rm_rf` alone accounts for the
whole plateau, and it multiplies with entries — but it is **not** either of the
two mechanisms that were guessed at:

* **not round-trip scheduling.** A message round trip under the same load is
  117 us, orders of magnitude below one file operation. (`@answer_ms` cites
  "48 CPU burners: p50 926 ms" as a loaded round-trip figure. It is not: that
  number is the *whole turn* — a mocked LLM call, a real sub-agent spawn with DB
  writes, and a second mocked call — from `sub_agent_tools_helpers.ex`'s fence
  sizing. The same file's *idle* status-read sample, p50 21 us, is the
  comparable one.)
* **not queueing behind other callers.** File operations *do* go through one
  global process — but it is `file_server_2`, not `:file_server`: that name is
  gone, and `Process.whereis/1` returns `nil` for it and a pid for
  `:file_server_2`, the only file-ish registered process on this OTP. (The ladder
  work independently traced ~1200 messages per 200 `rm_rf` into it.) This
  measurement has no other file I/O in it, though: the load is 32 CPU burners and
  an empty `rm_rf` is only a handful of round trips, so there is no queue to wait
  behind. What the ~9 ms is, is the *per-round-trip* cost — the file server has to
  be scheduled, and the operation does real work in the syscall path — which is why
  a plain message round trip is 117 us under the same load while a file round trip
  is milliseconds.

That the tail "survives moving every cross-process call out of
`Agent.terminate/2`" — the claim the previous comment carried — is consistent
with this: `File.rm_rf` is not a cross-process call terminate *makes*, it is a
library call inside `cleanup_tmp/2`, so an experiment that removed terminate's own
cross-process work would leave exactly this cost in place.

Real scratch directories are empty, so the empty-directory cost is the realistic
one: of the 25 directories visible during a probe run, 22 held 0 entries, 2 held
1, and one was not a directory. That is why the handshake produced a steady trickle of failures on a slow host rather
than obvious noise — it sat just under a 10 ms bound.

## The handshake's cost curve

The stop handshake, for agents that had all answered `:idle` (so provably not in
a turn), measured with the probe below.

`vampire` — 32 logical / 16 physical CPUs, suite at `max_cases: 16`:

| CPU burners | handshake (us) |
| --- | --- |
| 0 | 25 - 110 |
| 16 | 51 - 789 |
| 32 | 8472 - 9143 |
| 48 | 686 - 9030 |
| 64 | 4840 - 9063 |
| 96 | 5058 - 9074 |

The 32+ rows are a flat ~9 ms plateau, i.e. saturation alone brings the handshake
to within 10% of the old 10 ms bound. Add any other load on the host and it
crosses: a 48-burner probe run under concurrent compilation measured 7.6-10.9 ms
with 3 of 12 agents over 10 ms.

`celedyr` — 24 logical / 12 physical, an old AMD Opteron; the slow host the suite
must also pass on:

| max_cases | before (failures / detector) | after (failures / detector) |
| --- | --- | --- |
| 8 | 9 / 7 | 0-2 / **0** |
| 12 | 13 / 4 | 0-5 / **0** |
| 24 | 68 / 24 | 11-18 / **0** |

The "after" failures are a *range* because they are host-load dependent: this
branch measured 0 at 8, 1-5 at 12 and 11-18 at 24 across runs, and the independent
review measured 2 at 8. The detector count is **0 in every run**, which is the
claim that matters. (The pre-fix figures from the main checkout, before this
branch's diagnostics existed, were 5 / 2 at 8, 8 / 6 at 12 and 20 / 6 at 24.)
With an idle host celedyr's handshake is 172-500 us, so its failures came from
load, not from being slow as such. Every failure that remains is an
`ExUnit.TimeoutError` — `Mimic.stub`/`Mimic.allow` queueing on Mimic's single
server, plus a Postgres round trip — which is a separate workstream.

The probe above is a *controlled* load. The distribution across a real suite run
was measured separately, by instrumenting every teardown stop: 483 stops on the
fast host (max 4.35 ms) and 480 on celedyr at `max_cases` 8 (p50 596 us, p99
20.9 ms, max 39.3 ms), with no correct agent crossing the bound in either run.
Those figures come from the independent review of this branch, not from the probe
below.

## The fix

* The idle invariant is asserted from state, where it always belonged.
* `@stop_ms` became 150 ms and is documented as a liveness bound. Two margins,
  and they are different quantities: file-alone a handshake is 3.96 ms (~38x), and
  the worst handshake measured under full suite load is 39.3 ms (~3.8x). It is
  deliberately no larger, because two pins have to *reach* the bound to prove the
  gate can still fail, so the suite pays 2x it.
* A stop that misses the bound now reports the evidence — the sampled status, how
  long the stop took, and `Process.info/2` for the agent (status, queue length,
  current function and stacktrace) — which is what told "stopping, in
  `terminate/2`" apart from "wedged in a call".
* Pins: an idle agent with a *populated* scratch directory (20 files — a real
  `File.rm_rf` load rather than a stub, and deliberately small so the pin cannot
  flake on a loaded host) must not be reported; and the bound's floor is pinned
  through `stop_bound_ms/0` so it cannot be tightened back toward the handshake.

## Reproducing the probe

The probe is not kept in `test/`: it saturates every scheduler with burners, and
an excluded test file would count as uncovered lines against the coverage gate.
Drop it back in as `test/nest/agents/gate_probe_test.exs` to re-measure.

```elixir
defmodule Nest.Agents.GateProbeTest do
  # `async: false` because the probe deliberately saturates every scheduler.
  use Nest.DataCase, async: false

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.AgentTestLifecycle

  @burners_default 32
  @agents 12
  @out_dir "notes/test-runs"

  test "stop handshake for idle agents under burner load" do
    burners = String.to_integer(System.get_env("GATE_PROBE_BURNERS", "#{@burners_default}"))
    flags = :atomics.new(1, signed: false)
    _burners = Enum.map(1..burners//1, fn _ -> spawn_burner(flags) end)

    # Started and left alone: no turn, nothing parked. They are in their own
    # receive loops, which is the state a compliant test leaves them in.
    _agents = for _ <- 1..@agents, do: AgentTestHelpers.start_agent()

    result = AgentTestLifecycle.stop_test_agents()

    :atomics.put(flags, 1, 1)

    report = [
      "burners=#{burners} agents=#{@agents} owned=#{result.owned}",
      "in_flight=#{inspect(result.in_flight)}",
      "not_stopped=#{inspect(result.not_stopped)}",
      "samples_us=#{inspect(Enum.map(result.diag, fn {_s, _n, _smp, _k, us, _i} -> us end))}",
      "samples=#{inspect(result.diag, limit: :infinity, printable_limit: 4000)}"
    ]

    File.write!("#{@out_dir}/gate-probe-#{burners}.txt", Enum.join(report, "\n") <> "\n")

    assert result.owned == @agents
  end

  defp spawn_burner(flags), do: spawn(fn -> loop_until(flags) end)

  defp loop_until(flags) do
    if :atomics.get(flags, 1) == 0 do
      _ = Enum.reduce(1..200, 0, &(&1 + &2))
      loop_until(flags)
    else
      :ok
    end
  end
end
```

```sh
# on vampire (wrap full-suite runs in the lock: it is a shared measurement host)
GATE_PROBE_BURNERS=32 mix test test/nest/agents/gate_probe_test.exs
# on celedyr
ssh nat@celedyr 'flock -w 3600 /tmp/nest-celedyr.lock -c "cd ... && GATE_PROBE_BURNERS=32 mix test test/nest/agents/gate_probe_test.exs"'
```
