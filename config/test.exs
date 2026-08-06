import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide test partitioning in CI environment.
# Run `mix help test` for more information.
config :nest, Nest.Repo,
  username: System.fetch_env!("USER"),
  socket_dir: "/var/run/postgresql",
  database: "nest_test",
  pool_size: 20,
  ownership_timeout: 30_000,
  pool: Ecto.Adapters.SQL.Sandbox

# Agent persistence is required: `Agent.init/1` rejects
# spawn attempts with `{:error, :non_persistence_not_implemented}`
# when this flag is `false`. Tests that exercise persistence
# (the Agent test suite) must therefore run with a DataCase
# sandbox. `Nest.Persistence` exercises its own connection
# setup in `persistence_test.exs`.
config :nest, persistence: [enabled: true]

# Subagent tests need freshly-spawned children to land on
# `MockClient` rather than the real HTTP client. The default-
# on lets tests stay free of `Application.put_env` mutations,
# which would otherwise race with the existing
# `clone_agent_registration_test.exs`'s `delete_env` on_exit
# and break async test ordering. Production reads `false`
# (the third arg of `Application.get_env/3`) by default.
config :nest, force_subagent_mock: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nest, NestWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8WV9Gdd+psEoIYe7Z7ZBD0L8oFyR4AtsNLi3leF/8AmbYx99zeAAhXmxFfnWlVfv",
  server: false

# In test we don't send emails
config :nest, Nest.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# `argon2_elixir` defaults to a memory cost of `m=65536` and a
# time cost of `t=3` — appropriate for production but ~30ms per
# `hash_pwd_salt/1` call in tests, which adds ~3 seconds across
# the test suite given how many `Accounts.create_user/2` calls
# the multi-user tests make. Drop the cost to the minimum
# (`t=1, m=8`) in the test environment — the hashing still
# runs the full argon2id pipeline, so the test coverage of
# `Accounts.authenticate/2` exercises the real codepath.
config :argon2_elixir, t_cost: 1, m_cost: 8

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Use null adapter for Req in tests to prevent real HTTP requests.
# Per Req 0.7.1+, the adapter must be a module (not a function) —
# using a function here triggers the `IO.warn` deprecation in
# `Req.Request.adapter/1` on every request.
config :req, default_options: [adapter: Nest.Test.ReqNullAdapter]
