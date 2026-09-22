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

# `:hpu` tests exercise real Gaudi hardware and are skipped by default;
# run them with `mix test --include hpu` on an HPU host.
#
# `max_cases` defaults to `schedulers_online * 2`. The suite is DB- and
# message-passing-bound, and on very-high-core hosts that default
# oversubscribes enough to make the timing-sensitive `assert_receive`s
# flaky. Cap it at 32 while preserving the default on small machines.
ExUnit.configure(
  timeout: 5_000,
  exclude: [:hpu],
  max_cases: min(System.schedulers_online() * 2, 32)
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nest.Repo, :manual)

# Start the application for tests
Application.ensure_all_started(:nest)
