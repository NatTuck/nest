defmodule Nest.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Nest.Agents.ChildRegistry
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tokens.Tokenizer

  @impl true
  def start(_type, _args) do
    # Check system dependencies first
    check_system_dependencies!()

    # The canonical-workspace memo's table is owned by the application, so it
    # lives for the whole BEAM. Created lazily it was owned by whichever process
    # read a workspace first — an agent — and died with it.
    Nest.ProjectConfig.init_cache()

    # Start the cl100k_base vocabulary build here and await it last.
    #
    # `Tokenizer.load/0` is ~95ms of Rust-side work (parse the bundled
    # JSON, build the BPE vocabulary) and it is independent of the
    # supervision tree below it, so running it concurrently means boot
    # pays the *larger* of the two instead of their sum: `:nest`'s whole
    # start drops by ~46ms (interleaved warm runs measured 209.5ms ->
    # 163.6ms here and 264.4ms -> 218.0ms on a second host; the delta is
    # the claim, the absolute figures are host-dependent).
    # `:persistent_term` keeps the hot-path `Estimator` reads lock-free.
    #
    # The invariant this rests on is narrower than "nothing can observe a
    # half-loaded app", which is false. Children start in order, so
    # `NestWeb.Endpoint` binds its listener as soon as the tree start
    # returns (~46ms in) while the await below is still pending (~94ms
    # in): the endpoint is live, and serving, for roughly the last 48ms
    # of the load — and for as long as the 60s bound below if the load is
    # slow.
    #
    # So the real invariant is: *nothing may read the tokenizer before
    # `start/2` returns*. That covers more than a child's `init/1` — it
    # covers every runtime path reachable in that window, i.e. HTTP and
    # channel traffic and any `handle_continue`. `Nest.Tokens.Estimator`
    # enforces the consequence rather than trusting the constraint: with
    # the tokenizer unloaded it re-raises instead of falling back, so a
    # violation is a loud error and never a quietly wrong `chars/4` count.
    # Only `Estimator` reaches `Tokenizer.count/1`.
    #
    # The failure path's decision is covered directly: its body is
    # `Nest.Tokens.Estimator.fallback_or_reraise/4`, which takes the
    # `Tokenizer.loaded?/0` boolean as an argument, and both branches are
    # asserted in `test/nest/tokens/estimator_test.exs`. What is still not
    # covered end to end is the arrangement — erase the `:persistent_term`
    # key, then read through `Estimator` — which needs global state, hence
    # an `async: false` module plus a reload. The premise that boot *does*
    # load the tokenizer is pinned by the `Tokenizer.loaded?()` assertion
    # in `test/nest/tokens/tokenizer_test.exs`.
    #
    # The await is bounded so a hung load cannot wedge boot forever; 60s
    # is ~600x the measured load, so a load slow enough to hit it is a
    # real failure, not a slow machine.
    tokenizer_task = Task.async(&Tokenizer.load/0)

    base_children = [
      NestWeb.Telemetry,
      Nest.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:nest, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:nest, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nest.PubSub},
      # Start agent supervision tree
      Nest.Agents.Registry.child_spec(),
      ChildRegistry.child_spec(),
      Nest.Agents.Supervisor.child_spec(),
      {Task.Supervisor, name: Nest.Agents.TaskSupervisor},
      {Task.Supervisor, name: Nest.Models.TaskSupervisor},
      # Background shell-job manager (per-agent `shell-cmd background`)
      ShellJobs.child_spec(),
      # Endpoint probing + cache (started before Models so the model
      # manager can read probed discovery paths)
      Nest.EndpointCache,
      # On-disk cache of multi-modal probe verdicts, so a rescan does not
      # re-probe every model of every opted-in provider
      Nest.LLM.MultimodalCache,
      # Start model manager (queries auto-providers)
      Nest.Models
    ]

    # Add surgical reloader in development
    dev_children = if code_reloading?(), do: [NestWeb.SurgicalReloader], else: []

    children = base_children ++ dev_children ++ [NestWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nest.Supervisor]
    result = Supervisor.start_link(children, opts)

    :ok = Task.await(tokenizer_task, 60_000)

    result
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
