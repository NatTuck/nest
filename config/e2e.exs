import Config

# The end-to-end environment: a real server, a real browser, a throwaway
# database, and a stub model provider.
#
# Why its own environment rather than one of the two we have:
#
#   * `:test` cannot serve. `config/test.exs` puts the Repo on the SQL sandbox,
#     stubs the docker runner and points `Req` at a null adapter — all three are
#     right for a suite that never opens a socket, and all three are wrong for a
#     process that answers HTTP and talks to a provider.
#   * `:dev` cannot run on a runner. It takes its database and port from
#     `Nest.Config.Checkout` and connects over `/var/run/postgresql`, which a
#     service container does not share.
#
# So: the same shape as dev (real Repo, real Req, real assets from
# `priv/static`), with the connection taken from the environment so one file
# works on a developer's machine and on a CI runner, and no watchers.
#
# The user is seeded, along with the vocations and blueprints
# (`priv/repo/seeds.exs`); the space, the agent and the message are all created
# through the UI by the specs, which is the point of running them in a browser at
# all.

database = System.get_env("E2E_DB") || "nest_e2e"

# A unix socket locally, TCP in CI. `Postgrex` uses `socket_dir` when it is set
# and `hostname` otherwise, so exactly one of these is configured.
connection =
  case System.get_env("E2E_DB_HOST") do
    nil ->
      [
        username: System.get_env("E2E_DB_USER") || System.fetch_env!("USER"),
        socket_dir: System.get_env("E2E_DB_SOCKET_DIR") || "/var/run/postgresql"
      ]

    host ->
      [
        username: System.get_env("E2E_DB_USER") || "postgres",
        password: System.get_env("E2E_DB_PASSWORD") || "postgres",
        hostname: host,
        port: String.to_integer(System.get_env("E2E_DB_PORT") || "5432")
      ]
  end

config :nest, Nest.Repo, [database: database, pool_size: 10, stacktrace: true] ++ connection

# The browser connects to this port, so it has to be the one the specs' `baseURL`
# names. `code_reloader: false`: a reloader mid-run would swap code under a test
# that is watching a live socket.
#
# `secret_key_base` is `mix phx.gen.secret`'s output, pinned rather than read
# from the environment: this server only ever listens on 127.0.0.1 against a
# throwaway database, and a pinned value means a run cannot fail because the
# runner forgot to export one. It must be **at least 64 bytes** — Plug's cookie
# store refuses anything shorter, and every browser request goes through
# `:fetch_session`, so a short key is a 500 on every page rather than a warning.
config :nest, NestWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: String.to_integer(System.get_env("E2E_PORT") || "4010")
  ],
  secret_key_base: "lGWLMEPE1HQ4L5JrUU/SIixan5JDN0fZCn9TcO/4Wh9zN8h+R+U1A9zvfw/Uh9c/",
  server: true,
  check_origin: false,
  code_reloader: false

# A run is a stream of warnings from an app that has no provider keys; only
# errors are interesting, and the specs fail on a page error anyway.
config :logger, level: :warning

# Mail is not part of what the suite covers, and the api client it would reach
# for (hackney) is not a dependency — production points Swoosh at Req, dev and
# test turn it off.
config :swoosh, :api_client, false

# `Nest.Hostname` titles the page; pin it so a run does not depend on the host.
config :nest, :hostname, "e2ehost"
