# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

:inet_db.set_lookup([:native])

# Import build-time helper for git URL conversion
import_config "git_remote.exs"

config :nest,
  ecto_repos: [Nest.Repo],
  generators: [timestamp_type: :utc_datetime],
  source_url: Config.GitRemote.get_origin_url()

# Configure the endpoint
config :nest, NestWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NestWeb.ErrorHTML, json: NestWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Nest.PubSub,
  live_view: [signing_salt: "Y1PurR//"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :nest, Nest.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
