Mimic.copy(LangChain.Chains.LLMChain)
Mimic.copy(Req)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Nest.Repo, :manual)

# Start the application for tests
Application.ensure_all_started(:nest)
