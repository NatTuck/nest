Mimic.copy(Nest.LLM.OpenAIClient)
Mimic.copy(Req)
Mimic.copy(Nest.DotConfig)
Mimic.copy(Nest.LLM.MockClient)
Mimic.copy(Nest.Models)
Mimic.copy(Nest.Persistence)
Mimic.copy(Nest.Vocations)

ExUnit.configure(timeout: 5_000)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nest.Repo, :manual)

# Start the application for tests
Application.ensure_all_started(:nest)
