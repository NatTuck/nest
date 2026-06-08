defmodule Nest.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Check system dependencies first
    check_system_dependencies!()

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
      {Task.Supervisor, name: Nest.Agents.TaskSupervisor},
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

  defp check_system_dependencies! do
    case System.cmd("bwrap", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = parse_bwrap_version(output)

        if Version.compare(version, "0.9.0") in [:eq, :gt] do
          :ok
        else
          raise_system_dependency_error!("bubblewrap", version, "0.9.0")
        end

      {_output, _code} ->
        raise_system_dependency_error!("bubblewrap", nil, "0.9.0")
    end
  end

  defp parse_bwrap_version(output) do
    output
    |> String.split("\n")
    |> List.first()
    |> case do
      "bubblewrap " <> version -> String.trim(version)
      _ -> "0.0.0"
    end
  end

  defp raise_system_dependency_error!(package, current_version, min_version) do
    current_str = if current_version, do: " (found version #{current_version})", else: ""

    message = """
    System dependency check failed!

    #{package}#{current_str} is required but not found or is too old.
    Minimum version required: #{min_version}

    Please install the #{package} system package:
      - Debian/Ubuntu: sudo apt install #{package}
      - Fedora: sudo dnf install #{package}
      - Arch: sudo pacman -S #{package}
      - macOS: brew install #{package}
    """

    raise message
  end
end
