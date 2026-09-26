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
