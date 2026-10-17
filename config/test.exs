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
  pool_size: 40,
  ownership_timeout: 30_000,
  pool: Ecto.Adapters.SQL.Sandbox

# Subagent tests need freshly-spawned children to land on
# `MockClient` rather than the real HTTP client. The default-
# on lets tests stay free of `Application.put_env` mutations,
# which would otherwise race with the existing
# `clone_agent_registration_test.exs`'s `delete_env` on_exit
# and break async test ordering. Production reads `false`
# (the third arg of `Application.get_env/3`) by default.
config :nest, force_subagent_mock: true

# The Agent's bounded Stop fallback (see `Agent.Turn.Lifecycle.stop/2`)
# defaults to 2s in production. Tests that exercise a stop don't need to
# wait that long; the kill is synchronous, so the fallback timer can fire
# immediately and the suite stays fast under the tight host timeout.
config :nest, stop_fallback_ms: 1

# Keep unit tests independent of the host's `/dev`: pin HPU detection to
# none so the sandbox always takes the non-HPU path, while
# `hardware_test.exs` exercises detection against a `dev_root` fixture.
config :nest, hpu_device_paths: []

# The suite must never talk to a Docker daemon, and must never leave a
# container behind. The docker backend's default runner is
# `System.cmd("docker", argv)`; here it is an inert stub that reports "the
# daemon answered, and there is nothing there", which is the answer that
# leaves every code path in its no-op branch. The lifecycle tests pass their
# own `runner:` and assert the argv they expect.
#
# This covers the *setup* calls only — `inspect`, `start`, `image`, `build`,
# `run`, `ps`, `rm`. It does **not** cover the command an agent runs: that is the
# literal `docker exec -i …` string `Docker.command/3` builds and
# `Nest.Tools.ShellCmd` hands to erlexec, which never goes through the runner.
# So a test that runs a command through the docker backend would shell out to the
# real `docker` — and print an `[error]` from the failed exec — rather than being
# silently inert.
#
# No test does that today, and the reason is worth knowing because it is one line
# from false. Composing a prompt reads `AGENTS.md` only when the *agent's* mounts
# name a workspace: `Nest.Agents.Agent.SystemPrompt.agents_md_section/2`'s first
# clause returns `""` for `%Mounts{workspace: nil}` without calling
# `Sandbox.read/3` at all. An agent created through
# `Nest.Agents.create_agent/3` takes its workspace from that call's
# `:workspace_path` option — a clone or a spawned child takes it from its parent's
# mounts instead — and a space's own path reaches the root agent only through
# `Nest.Spaces.create_space_with_root_agent/2`. The one docker-space agent the
# suite starts names no workspace, so it never makes the read. A docker agent
# *with* a workspace would: it would fail against a container that is not there
# and print `sandbox_setup_failed`, at `:warning`.
config :nest, docker_runner: fn _argv -> {"", 0} end

# `Nest.Hostname.get/0` titles every page (and feeds
# `window.NEST_CONFIG.host`). Pin it so the layout tests assert on a
# fixed name instead of whatever machine they happen to run on.
config :nest, :hostname, "testhost"

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
