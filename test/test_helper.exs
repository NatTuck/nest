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
ExUnit.configure(timeout: 5_000, exclude: [:hpu])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nest.Repo, :manual)

# Start the application for tests
Application.ensure_all_started(:nest)
