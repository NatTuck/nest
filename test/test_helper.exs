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

# `timeout` is the per-test deadline. The ruling is that **every** timeout in the
# tests — implicit or explicit — is 2000 ms or lower, with no exceptions: *"If a
# test can't run under that, we need to fix it or consider removing it as
# untestable."* That includes this one, so it is 2000 ms, not the 5000 ms it was.
#
# It does not affect the suite's 5 s gate (`scripts/precommit-test.sh`): that
# budget is *throughput* across `max_cases` concurrent tests, not the deadline of
# any single one, so this value cannot move the suite toward 5 s either way. What
# it does is bound how long a test may spend before we call it broken — and at
# 2000 ms the tests that lose a scheduling race become visible rather than
# hidden. `notes/sketchy-slow-tests.md` §2 records the failures, and §10 the two
# shared serialization points that have to be fixed for the ceiling to hold.
#
# `max_cases` defaults to `schedulers_online * 2`. The suite is
# DB- and message-passing-bound, and over-subscribing the schedulers
# (32 cases on a 32-scheduler host) causes enough contention that the
# timing-sensitive `assert_receive` fences flake. Cap at 24, which is
# both faster (less contention) and stable on the reference host while
# preserving the default on small machines.
ExUnit.configure(
  timeout: 2_000,
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
#
# The endpoint's plug stack belongs in this list: `Plug.Static.init/1` in
# particular is loaded on the first request, and a `page_controller_test` has
# been observed burning its whole per-test deadline in `code_server.call/1`
# waiting for exactly that. See `lib/nest_web/endpoint.ex`.
for mod <- [
      Jason,
      Jason.Decoder,
      Jason.Encoder,
      Postgrex.Extensions.JSONB,
      Postgrex.DefaultTypes,
      Plug.Static,
      Plug.RequestId,
      Plug.Telemetry,
      Plug.Parsers,
      Plug.MethodOverride,
      Plug.Head,
      Plug.Session,
      NestWeb.Router,
      NestWeb.Endpoint
    ],
    Code.ensure_loaded?(mod) do
  :ok
end

# Warm the agent-start path (#21).
#
# `Agent.init/1` runs inside the supervisor's critical section —
# `DynamicSupervisor.start_child/2` blocks for the whole of it — so its
# first-call cost is paid once per BEAM but charged to whichever test
# happens to start an agent first, and the start-up burst (many tests
# starting agents at once) serialises that cost into one queue.
#
# Measured on this suite with `Agent.init/1` instrumented, before/after:
# init mean 5.01ms -> 1.78ms, total init work across the suite
# 2620ms -> 941ms, the start-up burst's mean 29ms -> 1.93ms, and caller
# waits over 100ms 12 -> 0. The suite itself goes 8.4s -> 6.2s. Paying
# the first-call cost here moves it out of the timed suite, exactly like
# the code-server warm-up above.
#
# `Tools.get_functions/2` is the single biggest term (45% of all init
# time), so every group is warmed rather than a representative subset.
_ = Nest.DotConfig.load()
_ = Nest.Agents.Agent.Config.configured_max_depth()
_ = Nest.Agents.Agent.Config.configured_context_limit("warmup")
_ = Nest.Agents.Agent.Config.configured_provider_default_context_limit("model-studio")

_ =
  Nest.Agents.Agent.Config.create_client_config(%{
    name: "qwen3.5-plus",
    provider: "model-studio"
  })

_ =
  Nest.Agents.Agent.Init.initial_context_limit(%{
    name: "qwen3.5-plus",
    provider: "model-studio"
  })

_ = Nest.ProjectConfig.section(nil)
_ = Nest.Agents.Agent.TmpSpace.create(0, "warmup")

_ =
  Nest.Tools.get_functions(
    Nest.Tools.Groups.expand(Nest.Tools.Groups.all()),
    Nest.Sandbox.Mounts.new(nil, nil)
  )
