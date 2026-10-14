# Measures the cost of forcing Mimic to copy every module that
# test/test_helper.exs marks with `Mimic.copy/1`, three ways. This is the
# measurement behind `notes/mimic-parallel-copy.md` and the eager-copy block in
# test/test_helper.exs; it is a probe to be run by hand, not part of the suite.
#
# Under plain `mix test` (no `--cover`), `Mimic.copy/1` only *marks* a module.
# The copy itself is done by the first line of `Mimic.Server.stub/expect/reject`,
# `Coordinator.ensure_copied/1`, and `Mimic.Coordinator` performs it inside its
# own `handle_call`. A GenServer serialises its `handle_call`s, so the copies
# cannot overlap -- which is what `coord_parallel` below demonstrates.
#
#   serial          Mimic.Coordinator.ensure_copied/1 per module, one at a time.
#   coord_parallel  The same call, but from `System.schedulers_online()`
#                   concurrent tasks. The control: if the Coordinator really
#                   does the compile inside its `handle_call`, this costs the
#                   same as `serial` no matter how many tasks are thrown at it.
#   parallel        Mimic.Module.replace!/2 per module, driven from the caller
#                   via Task.async_stream/3, so the compilations can overlap.
#
# One mode per fresh VM, run from the project root:
#
#   MIX_ENV=test NEST_MIMIC_PROBE=serial mix run scripts/mimic-copy-probe.exs
#
# The `parallel` mode calls `Mimic.Module.replace!/2` directly. That module is
# `@moduledoc false`, so this reaches into an internal of the dependency -- it
# does not patch it. It is the only caller-side route, because every route
# through the Coordinator serialises.

all = [
  Nest.LLM.OpenAIClient,
  Req,
  Nest.DotConfig,
  Nest.LLM.MockClient,
  Nest.LLM.AnthropicClient,
  Nest.Models,
  Nest.Persistence,
  Nest.Vocations,
  Nest.Agents.Agent,
  Nest.Agents.Agent.Config,
  Nest.Agents,
  Nest.Agents.Supervisor,
  Phoenix.Channel,
  Nest.ChatModel,
  Nest.Agents.Registry,
  Task.Supervisor,
  Nest.Sandbox,
  Nest.Tools.ShellCmd
]

mods =
  Enum.filter(all, fn m ->
    case Code.ensure_loaded(m) do
      {:module, ^m} ->
        true

      other ->
        IO.puts("PROBE skip #{inspect(m)}: #{inspect(other)}")
        false
    end
  end)

mode = System.get_env("NEST_MIMIC_PROBE", "serial")

IO.puts(
  "PROBE start mode=#{mode} modules=#{length(mods)} schedulers=#{System.schedulers()} " <>
    "online=#{System.schedulers_online()} coordinator=#{inspect(Process.whereis(Mimic.Coordinator))}"
)

# Mark every module, exactly as `Mimic.copy/1` does (minus the ExUnit hook).
for m <- mods do
  :ok = Mimic.Coordinator.mark_to_copy(m, [])
end

{t, _} =
  :timer.tc(fn ->
    case mode do
      "serial" ->
        for m <- mods, do: :ok = Mimic.Coordinator.ensure_copied(m)

      "coord_parallel" ->
        mods
        |> Task.async_stream(fn m -> Mimic.Coordinator.ensure_copied(m) end,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: 120_000
        )
        |> Stream.run()

      "parallel" ->
        mods
        |> Task.async_stream(fn m -> Mimic.Module.replace!(m, []) end,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: 120_000
        )
        |> Stream.run()
    end
  end)

copied = Enum.count(mods, &Mimic.Module.copied?/1)

IO.puts("PROBE copy mode=#{mode} copy_ms=#{div(t, 1000)} copied=#{copied}/#{length(mods)}")

# Functional check: a copied module's stub must actually intercept a call.
# A parallel copy that produced broken mocks would pass the `copied?` count and
# fail here.
Mimic.stub(Req, :get!, fn _url -> {:ok, :probe_stub} end)
IO.puts("PROBE stub_works=#{inspect(Req.get!(:probe))}")
