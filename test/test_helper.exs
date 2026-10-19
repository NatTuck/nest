# Modules Mimic swaps for a proxy. Written once, and used for both the
# `Mimic.copy/1` calls below and the eager copy that follows them, so the two
# cannot drift apart.
#
# Copied here, never per-test: Mimic's copy swaps the module for its proxy and
# re-imports coverdata around the swap, so a copy that runs *during* the suite
# (from an async module's `setup`) makes that module's coverage depend on test
# order — enough to swing the total across the `minimum_coverage` gate in
# ./coveralls.json. `Nest.ChatModel` and `Nest.Agents.Registry` are both
# exercised by other tests, so they belong in this list.
#
# `Task.Supervisor` is here for the same reason, and because it is used
# concurrently by other tests: the give-up's delivery stubs it to force a
# refusal, and a per-test copy would swap the module out from under whatever
# else is starting a task.
#
# `Nest.Sandbox` and `Nest.Tools.ShellCmd` are here for the same reason: the
# BatchSizer preflight tests stub their `stat`/`execute_raw` entry points, and a
# per-test copy would re-import coverdata mid-suite — with `Sandbox` exercised
# by many other tests, that is the worst module to swap per-test.
mimic_modules = [
  {Nest.LLM.OpenAIClient, []},
  {Req, []},
  {Nest.DotConfig, []},
  {Nest.LLM.MockClient, []},
  {Nest.LLM.AnthropicClient, []},
  {Nest.LLM.MultimodalCache, []},
  {Nest.Models, []},
  {Nest.Persistence, []},
  {Nest.Vocations, []},
  {Nest.Agents.Agent, []},
  {Nest.Agents.Agent.Config, []},
  {Nest.Agents.Agent.Init, []},
  {Nest.Agents, []},
  {Nest.Agents.Supervisor, []},
  {Phoenix.Channel, []},
  {Nest.ChatModel, []},
  {Nest.Agents.Registry, []},
  {Task.Supervisor, []},
  {Nest.Sandbox, []},
  {Nest.Tools.ShellCmd, []}
]

Enum.each(mimic_modules, fn {module, opts} -> Mimic.copy(module, opts) end)

# Force those copies to happen now, before the suite runs, rather than lazily on
# the first `stub`/`expect`/`reject` that targets each module.
#
# `Mimic.copy/1` only *marks* a module for copying (unless `:cover` is enabled
# for it). The copy itself is done by the first line of
# `Mimic.Server.stub/expect/reject`, `Coordinator.ensure_copied/1`, and
# `Mimic.Coordinator` performs it inside its own `handle_call`:
# `handle_call({:ensure_copied, …})` -> `ensure_module_copied/2` ->
# `Mimic.Module.replace!/2`, which recompiles the renamed original and then
# compiles a whole mock module. A GenServer serialises its `handle_call`s, so
# every module's copy is serialised against every other's, and it is paid
# *during* the suite, while the host is already saturated with concurrent tests.
# Measured for the 18 modules the list held at the time: 712 ms on a
# 32-scheduler host and 3.0 s on the 24-scheduler one, all of it serial.
#
# Doing that through `Mimic.Coordinator.ensure_copied/1`, even from concurrent
# callers, does not help — it is the same serialising `handle_call` (measured:
# 716 ms with 32 concurrent callers vs 712 ms serial on the 32-scheduler host,
# 2.9 s either way on the other). So the copies are driven from here, in
# parallel, through `Mimic.Module.replace!/2`, which is 5.3-6.6x faster
# (135/124 ms and 457/499 ms respectively) and still produces working mocks.
#
# `Mimic.Module` is `@moduledoc false`, so this reaches into an internal of the
# dependency — it does not patch it. It is safe only because a module that is
# already copied is skipped: under `--cover`, `Mimic.copy/1` has already copied
# each module inside the Coordinator and recorded the coverdata path that
# `reset/1` needs to restore, and copying it a second time here would throw that
# away. In the no-cover case `Mimic.Module.replace!/2` returns `:ok`, so the
# Coordinator's `modules_beam` stays empty exactly as it would have on the lazy
# path, and the modules stay in `modules_to_be_copied` (put there by
# `mark_to_copy/2`) so `reset/1` is unaffected.
#
# The copies now happen before `ExUnit.start()` and before the warm-up blocks
# below, so on this path the warm-up and the suite run against Mimic's proxies
# from the start, where the lazy path ran the warm-up against the real modules
# and swapped each one only on its first `stub`/`expect`. (`mix test` starts the
# application itself, before this file is loaded, so the application's own boot
# is unaffected either way.) That is harmless — an unstubbed proxy delegates to
# the original, and both arms are 2429 tests / 0 failures with identical
# coverage — but it is a real difference in what the boot path exercises, and
# the A/B cannot separate it from the contention effect.
#
# `NEST_MIMIC_EAGER_COPY` selects the path so the suite can be A/B'd on one
# tree: `off` is the old lazy behaviour, `serial` the old eager one. Both are
# measurement switches, not settings to run the suite with. Note that `off`
# silently disables the fix *and* skips the fail-loud check below, so an `off`
# run cannot notice that the copies did not happen; it exists only to reproduce
# the pre-change baseline.
eager_copy_mode = System.get_env("NEST_MIMIC_EAGER_COPY", "parallel")

already_copied =
  Enum.count(mimic_modules, fn {module, _opts} -> Mimic.Module.copied?(module) end)

{elapsed_us, :ok} =
  :timer.tc(fn ->
    case eager_copy_mode do
      "off" ->
        :ok

      "serial" ->
        Enum.each(mimic_modules, fn {module, _opts} ->
          :ok = Mimic.Coordinator.ensure_copied(module)
        end)

      "parallel" ->
        mimic_modules
        |> Task.async_stream(
          fn {module, opts} ->
            if Mimic.Module.copied?(module) do
              :ok
            else
              Mimic.Module.replace!(module, opts)
            end
          end,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          # Boot scaffolding that runs outside ExUnit, so this is not a test
          # fence and no fence budget applies to it. 60 s mirrors Mimic's own
          # `@long_timeout` for this same operation (`ensure_copied/1` in
          # deps/mimic/lib/mimic/coordinator.ex).
          timeout: 60_000
        )
        |> Stream.run()

      other ->
        raise ArgumentError,
              "NEST_MIMIC_EAGER_COPY must be off, serial or parallel, got #{inspect(other)}"
    end
  end)

# Fail loudly if the eager copy did not take. A silent no-op here would leave
# every copy being made lazily during the suite, which is the thing this block
# exists to prevent, and the suite would still pass — just slowly, and with the
# contention that makes it flaky.
if eager_copy_mode != "off" do
  not_copied =
    for {module, _opts} <- mimic_modules, not Mimic.Module.copied?(module), do: module

  if not_copied != [] do
    raise "Mimic eager copy did not take for #{inspect(not_copied)}"
  end
end

if System.get_env("NEST_MIMIC_COPY_TIMING") do
  IO.puts(
    "NEST_MIMIC_COPY_MS=#{div(elapsed_us, 1000)} mode=#{eager_copy_mode} " <>
      "already_copied=#{already_copied}/#{length(mimic_modules)}"
  )
end

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
# `NEST_TEST_DURATIONS=1` adds the suite-time instrument (#94): per-module
# totals in the *real* parallel run, which `--slowest` cannot give because it
# implies `--trace`. Off by default, so a normal run pays nothing for it.
duration_formatters =
  case System.get_env("NEST_TEST_DURATIONS") do
    value when value in [nil, ""] -> []
    _set -> [Nest.Test.DurationSummary]
  end

ExUnit.configure(
  timeout: 3_000,
  max_cases: Nest.Test.MaxCases.real_cpus(),
  formatters: [ExUnit.CLIFormatter | duration_formatters]
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
#
# `Argon2` is here from an observed frame, like the rest: a `--cover` run on a
# loaded host lost four tests in `agent_channel_needs_repair_test.exs`'s setup to
# a 3000 ms `ExUnit.TimeoutError` whose innermost frame was
# `:code_server.call/1` reached from `:error_handler.undefined_function/3` ->
# `Argon2.hash_pwd_salt/2` -> `Nest.Accounts.put_password_hash/2`. The first user
# a run creates pays that load, so whichever test happens to create one first is
# charged for it.
#
# `Argon2.Base` is an *inference* from reading the dep, not an observed frame: it
# carries `@compile {:autoload, false}` and `@on_load {:init, 0}`, which is where
# the NIF is loaded, so `Argon2.hash_pwd_salt/2` cannot have run without loading
# it. Warming it here is what removes that first-call cost.
for mod <- [
      Argon2,
      Argon2.Base,
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

# Warm the TOML encoder chain (#21).
#
# `Writer.save_providers/2`'s first call in a VM loads modules lazily inside
# `TomlElixir.encode/1`, and the code server is shared, so the first call is
# charged to whichever test happens to save first — inside that test's 3000 ms
# deadline. Measured on this host, in a full `mix test` run: 83 ms for the
# first `TomlElixir.encode/1`, 100 ms for the first `Writer.save_providers/2`,
# and once 630 ms and once 1.18 s, against 45 µs for the same first call in an
# idle VM and ~350 µs hot. Paying it here, before any deadline, moves it out of
# every test's window exactly like the code-server and agent-start warm-ups
# above; it also fixes `writer_test.exs`, whose first save pays the same cost.
#
# The call takes a non-empty map on purpose. `TomlElixir.encode(%{})` loads
# `TomlElixir.Encoder.Serializer` but short-circuits before it reaches
# `TomlElixir.Encoder.Helpers`, so an empty table does not warm both modules
# this exists to warm. One key is enough: `Helpers.encode_key/1` (and, for the
# string value, `Helpers.escape_string/1`) then load.
_ = TomlElixir.encode(%{"warmup" => "warmup"})

# Fail loudly if the warm-up did not take, so a future reader cannot delete the
# line above as dead code and let the flake return silently.
#
# `:code.is_loaded/1` and not `Code.ensure_loaded?/1`: the latter *loads* the
# module it is asked about, so it reports every module as loaded whether or not
# the warm-up ran, and this guard would then pass over a deleted warm-up. (The
# `:nest` module list above uses `Code.ensure_loaded/1` deliberately — there the
# point *is* to load.) `:code.is_loaded/1` answers `false` for a module that is
# not loaded and a `{:file, _}` tuple once it is, which is what `Enum.reject/2`
# reads as "not loaded".
not_loaded =
  Enum.reject(
    [TomlElixir.Encoder.Serializer, TomlElixir.Encoder.Helpers],
    &:code.is_loaded/1
  )

if not_loaded != [] do
  raise "TOML encoder warm-up did not load #{inspect(not_loaded)}"
end

# Warm the `Inspect` chain that a config refusal's *message* needs.
#
# `FieldValidation` and `ModelValidation` build their message with
# `inspect(value)`, and `Inspect` is not loaded at boot. So the first refusal in
# a VM pulls `Inspect`, `Inspect.Opts` and the value's `Inspect.*` implementation
# through the shared code server — inside whichever test happens to refuse a
# config value first, which is a `save_providers` assertion bounded at 100 ms.
#
# Measured: 639 us for the first refusal in an idle VM, 5 us for the second, and
# **38 ms** for the first under 64 CPU burners against a 100 ms bound — which is
# how `providers_test.exs`'s "replies invalid_payload for a model context-limit
# the runtime rejects" flaked under the full suite while passing alone and under
# the whole channel directory. Same class as the TOML warm-up above, and the
# same remedy: pay it here, before any deadline.
#
# **The honest limit, so this does not overclaim.** The *cost* is measured; the
# gate failure it is meant to explain was never reproduced — at the failing seed
# the channel directory plus controllers is green **with and without** this
# block. So the warm-up rests on the measured load cost, not on a before/after,
# and if that test ever fails again this diagnosis is falsified: reproduce at the
# suite's real concurrency rather than with synthetic burners.
#
# The values are one per type a config value can actually have, because
# `inspect/1` dispatches on the argument's type. A TOML file or a GUI JSON
# payload can carry a string, an integer, a float, a boolean, a list, a map or
# null, so all of those protocols are warmed below — an earlier version warmed
# only Integer/BitString/Map and left `Inspect.List` cold, while
# `providers_test.exs` refuses `api_key = []` and the `tags` / `multi-modal`
# refusals inspect lists. (A tuple cannot arrive from either source.)
for value <- [0, 0.5, "", true, [], %{}, nil] do
  try do
    Nest.DotConfig.FieldValidation.positive_integer(value, "warmup", "warmup")
  rescue
    _ -> :ok
  end
end

# Fail loudly if it did not take, like the warm-up above: `:code.is_loaded/1`
# rather than `Code.ensure_loaded?/1`, so deleting the block above cannot leave
# this check passing over a cold chain.
not_loaded =
  Enum.reject(
    [
      Inspect,
      Inspect.Opts,
      Inspect.Integer,
      Inspect.Float,
      Inspect.BitString,
      Inspect.Atom,
      Inspect.List,
      Inspect.Map
    ],
    &:code.is_loaded/1
  )

if not_loaded != [] do
  raise "Inspect warm-up did not load #{inspect(not_loaded)}"
end

# Warm `LazyHTML`.
#
# `LazyHTML` is a Rust NIF, so the first call in a VM pays the module load and
# the NIF load together, and it is paid by whichever test parses HTML first.
# `page_controller_test.exs` is the only caller, and its first
# `LazyHTML.from_document/1` (the favicon assertions, around line 108) runs
# inside a controller test the suite bounds — observed as a timeout *inside*
# `from_document/1` while the same file passed alone. That is the same shape as
# the TOML and Inspect warm-ups above: a one-off cost landing inside somebody
# else's deadline.
#
# Measured in an idle VM, first call vs second: 1787 us vs 61 us. A ~2 ms load
# cannot by itself produce a timeout; what makes it one is contention — under
# full-suite concurrency the load queues on the shared code server behind every
# other first load. Warming pays it before any deadline rather than making it
# smaller. What it therefore does *not* establish is whether that test's own
# deadline is too tight on a loaded host: the warm-up removes a one-off cost, it
# does not re-measure the bound.
#
# The document is a real one rather than `""`, because the NIF loads on the
# parse and an empty string is the path least likely to touch it.
warmup_html = "<html><head><title>warmup</title></head></html>"

# Rescued so that the guard below can actually fire. Without the rescue, a
# failed warm-up raises here and the guard is unreachable — a check that cannot
# fail is worse than no check, because a reader counts it as one.
try do
  document = LazyHTML.from_document(warmup_html)
  _ = LazyHTML.text(LazyHTML.query(document, "title"))
rescue
  _ -> :ok
end

# Fail loudly if it did not take, like the guards above. `:code.is_loaded/1`
# returns `{:file, path}` rather than `true`, so this compares against `false`
# explicitly instead of relying on truthiness.
if :code.is_loaded(LazyHTML) == false do
  raise "LazyHTML warm-up did not load LazyHTML"
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
_ = Nest.Agents.Agent.TmpSpace.create(0, "warmup", "bwrap")

_ =
  Nest.Tools.get_functions(
    Nest.Tools.Groups.expand(Nest.Tools.Groups.all()),
    Nest.Sandbox.Mounts.new(nil, nil)
  )

# Remove this BEAM's scratch root, and with it every space directory and agent
# scratch the suite left behind — including the `space-0/warmup` the block above
# creates. The suite exits normally (production is killed instead), so unlike
# production it can clean up after itself; without this, one root per run
# accumulates under `/tmp/nest`, which is exactly what issue #92 was about.
ExUnit.after_suite(fn _result -> Nest.Agents.Agent.TmpSpace.remove_own_root() end)
