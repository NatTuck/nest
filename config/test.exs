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

# Disable agent persistence in tests. The agent process
# runs in a child of the test process; the Ecto Sandbox's
# private-mode connection (async tests) doesn't survive
# the test's lifecycle, and the test process exits before
# the agent's async writes complete, so a sync `Repo.insert`
# from the agent would race the test cleanup and fail.
# `Persistence` is still exercised by its own test
# (persistence_test.exs) which uses its own connection
# setup that doesn't depend on the agent's lifecycle.
config :nest, persistence: [enabled: false]

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

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Use null adapter for Req in tests to prevent real HTTP requests
config :req, default_options: [adapter: &Nest.Test.ReqNullAdapter.run/1]
