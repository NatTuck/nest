defmodule Nest.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      NestWeb.Telemetry,
      Nest.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:nest, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:nest, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nest.PubSub},
      # Start agent supervision tree
      Nest.Agents.Registry.child_spec(),
      Nest.Agents.Supervisor.child_spec(),
      # Start model manager (queries auto-providers)
      Nest.Models
    ]

    # Add surgical reloader in development
    dev_children = if code_reloading?(), do: [NestWeb.SurgicalReloader], else: []

    children = base_children ++ dev_children ++ [NestWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nest.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NestWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp code_reloading? do
    endpoint_config = Application.get_env(:nest, NestWeb.Endpoint, [])
    Keyword.get(endpoint_config, :code_reloader, false)
  end
end
