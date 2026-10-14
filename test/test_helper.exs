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

# `timeout` is the per-test deadline: a **failure bound**, deliberately set above
# the fences so a fence can report its own failure instead of dying as
# `ExUnit.TimeoutError` with no diagnostic. Fences and waits in `test/` are 1000 ms
# (the teardown's answer wait in `AgentTestLifecycle` is the
# one documented exception, and it goes *down*, not up); this is 3000 ms.
#
# It does not affect the suite's 5 s gate (`scripts/precommit-test.sh`): that budget
# is *throughput* across `max_cases` concurrent tests, not the deadline of any single
# one, so this value cannot move the suite toward 5 s either way.
#
# `max_cases` is the *physical* core count (see `Nest.Test.MaxCases`), not the
# logical one. Measured on this host: 8 cases -> 0 failures, 16 -> 2, 24 -> 12, so
# the suite is contention-bound above its real core count and over-subscribing the
# schedulers is what produces fence misses. There is deliberately no ceiling: on a
# 32-core/64-thread host this sets 32.
ExUnit.configure(
  timeout: 3_000,
  max_cases: Nest.Test.MaxCases.real_cpus()
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
#
# The rest of the request path's dependencies are here for the same reason, and
# each was added from an observed frame rather than from a guess. Reading the
# `ExUnit.TimeoutError` stacktraces whose innermost frame is
# `:code_server.call/1` names the *call site* that triggered the lazy load, and
# reading that call site names the module it was waiting for. The frames seen so
# far, and what each pulls in:
#
#   * `Plug.Session.init/1` (plug session.ex:57, `store.init/1`)
#     -> `Plug.Session.COOKIE`;
#   * `Plug.Conn.put_resp_cookie/4` (plug conn.ex:1716)
#     -> `Plug.Conn.Cookies`;
#   * `Phoenix.Controller.protect_from_forgery/2` -> `Plug.CSRFProtection`;
#   * `Phoenix.Controller.template_render_to_iodata/4` -> `Phoenix.Template`,
#     and through it the HEEx engine (`Phoenix.LiveView.HTMLEngine`) for the two
#     `.heex` templates in `lib/nest_web`;
#   * `NestWeb.Router.__match_route__/3` -> the pipeline's plugs, i.e. the
#     `Phoenix.Controller` entry points.
#
# `Code.ensure_loaded?/1` is enough for each: what is being removed is the
# *load* — one code-server round trip per module — and it does not matter which
# call site would have paid it.
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
      Plug.Conn,
      Plug.Conn.Cookies,
      Plug.Conn.Query,
      Plug.CSRFProtection,
      Plug.Session.COOKIE,
      Phoenix.Controller,
      Phoenix.Template,
      Phoenix.HTML,
      Phoenix.LiveView,
      Phoenix.LiveView.HTMLEngine,
      NestWeb.Router,
      NestWeb.Endpoint
    ],
    Code.ensure_loaded?(mod) do
  :ok
end

# Preload the application's own modules (#21).
#
# The list above covers the hot *dependencies*; `:nest`'s own modules are
# loaded lazily on their first call, and under host load that is where the
# suite actually stalls. Instrumented at `max_cases: 16` with 16 CPU
# burners (an idle host does not reproduce it at all), `:code_server.call/1`
# was the innermost frame of 45 of 142 failures, and the code server's
# message queue reached 35-43 — the deepest queue in the run, above
# `Mimic.Coordinator` (<= 14) and the `DynamicSupervisor` (<= 25).
#
# Preloading every `:nest` module removes those frames, and the
# `Supervisor.start_*` ones with them (45 -> 6, 17 -> 0 of 142), and the
# failure count follows: 142 -> 117 over 16 interleaved burner-loaded seeds
# (mean 8.9 -> 7.3 per run, paired t = 3.3, 11 seeds better / 2 worse / 3
# tied). What is left is Mimic's global coordinator (95 of 117).
#
# `mix test --preload-modules` is NOT the way to do this: `Mix.Tasks.Test`
# parses the switch but only forwards it to `app.start` under `--slowest`,
# so the CLI flag is a no-op here.
#
# A `nil` or empty list would leave every `:nest` module loading lazily again —
# exactly the serialisation this block exists to remove — so fail loudly rather
# than silently skipping the warm-up: a reader must not believe a fix is in
# force when it is not.
modules =
  case Application.spec(:nest, :modules) do
    [_ | _] = modules -> modules
    other -> raise "expected a non-empty :nest module list to preload, got #{inspect(other)}"
  end

for mod <- modules do
  Code.ensure_loaded(mod)
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
