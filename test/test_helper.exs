Mimic.copy(Nest.LLM.OpenAIClient)
Mimic.copy(Req)
Mimic.copy(Nest.DotConfig)
Mimic.copy(Nest.LLM.MockClient)
Mimic.copy(Nest.LLM.AnthropicClient)
Mimic.copy(Nest.Models)
Mimic.copy(Nest.Persistence)
Mimic.copy(Nest.Vocations)
Mimic.copy(Nest.Agents.Agent)
Mimic.copy(Nest.Agents.Agent.Config)
Mimic.copy(Nest.Agents)
Mimic.copy(Nest.Agents.Supervisor)
Mimic.copy(Phoenix.Channel)

# Copied here, never per-test: Mimic's copy swaps the module for its proxy and
# re-imports coverdata around the swap, so a copy that runs *during* the suite
# (from an async module's `setup`) makes that module's coverage depend on test
# order — enough to swing the total across the `minimum_coverage` gate in
# ./coveralls.json. `Nest.ChatModel` and `Nest.Agents.Registry` are both
# exercised by other tests, so they belong in this list.
Mimic.copy(Nest.ChatModel)
Mimic.copy(Nest.Agents.Registry)
# `Task.Supervisor` is copied here for the same reason, and because it is used
# concurrently by other tests: the give-up's delivery stubs it to force a
# refusal, and a per-test copy would swap the module out from under whatever
# else is starting a task.
Mimic.copy(Task.Supervisor)

# `Nest.Sandbox` and `Nest.Tools.ShellCmd` are copied here for the same reason:
# the BatchSizer preflight tests stub their `stat`/`execute_raw` entry points,
# and a per-test copy would re-import coverdata mid-suite — with `Sandbox`
# exercised by many other tests, that is the worst module to swap per-test.
Mimic.copy(Nest.Sandbox)
Mimic.copy(Nest.Tools.ShellCmd)

# `timeout` is a **failure bound, not a synchronization number**: it turns a
# hung test into a failed test instead of a hang. It decides no outcome, so it is
# deliberately **not** subject to `#21`'s 2000 ms cap. That cap covers waits that
# decide outcomes — `assert_receive`/`refute_receive` fences, `receive ... after`
# clauses, `GenServer.call`/`:sys.*` timeouts, helper defaults — and every one of
# those in `test/` is at or under 2000 ms. This value only bounds how long we
# wait before calling a test broken.
#
# A failure bound has one correct property: it must sit comfortably above the
# worst-case legitimate test duration. The slowest single test here measures
# **1680 ms serially** (`mix test --slowest`, seed 301962, 2369 tests); the next
# is 918 ms. At 2000 ms that leaves ~320 ms of headroom, which is not a bound but
# a coin flip — under 24-way concurrency it landed tails, and three consecutive
# full runs gave 9 / 11 / 6 failures with only one test common to the first two.
# `AGENTS.md` rates a sometimes-failing test as much worse than an always-failing
# one, so 5_000 ms is the headroom. A genuinely stuck test still fails inside it.
#
# It also does not affect the suite's 5 s gate (`scripts/precommit-test.sh`):
# that budget is *throughput* across `max_cases` concurrent tests, not the
# deadline of any single one. Lowering this number cannot move the suite toward
# 5 s — it only converts slow tests into failed ones. The two shared
# serialization points that make setup slow (and are the real #21 work) are
# written up in `notes/sketchy-slow-tests.md`.
#
# `max_cases` defaults to `schedulers_online * 2`. The suite is
# DB- and message-passing-bound, and over-subscribing the schedulers
# (32 cases on a 32-scheduler host) causes enough contention that the
# timing-sensitive `assert_receive` fences flake. Cap at 24, which is
# both faster (less contention) and stable on the reference host while
# preserving the default on small machines.
ExUnit.configure(
  timeout: 5_000,
  max_cases: min(System.schedulers_online() * 2, 24)
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nest.Repo, :manual)

# Start the application for tests
Application.ensure_all_started(:nest)

# Warm the code server. `interactive` code-loading mode routes every
# module's FIRST call through the single global code server. Under
# concurrent async tests, many processes hit lazy module loads (Jason
# JSONB decoding in Postgrex, app modules) at once and serialize on
# that one process, which manifests as multi-second stalls. Eagerly
# loading the hot modules before the suite starts removes the race.
for mod <- [
      Jason,
      Jason.Decoder,
      Jason.Encoder,
      Postgrex.Extensions.JSONB,
      Postgrex.DefaultTypes
    ],
    Code.ensure_loaded?(mod) do
  :ok
end
