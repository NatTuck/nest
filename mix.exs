defmodule Nest.MixProject do
  use Mix.Project

  def project do
    [
      app: :nest,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 80]
      ],
      test_ignore_filters: [
        &String.starts_with?(&1, "test/support/credo/")
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Nest.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test) do
    test_support_files =
      Path.wildcard("test/support/**/*.ex")
      |> Enum.reject(&String.contains?(&1, "credo/"))

    ["lib" | test_support_files]
  end

  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:toml, "~> 0.7.0"},
      {:toml_elixir, "~> 3.1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:mimic, "~> 2.3", only: :test},
      {:phoenix_copy, "~> 0.1.4", only: :dev},
      {:unique_names_generator, "~> 0.2.0"},
      # `:erlexec`'s `exec` gen_server sleeps a hardcoded 350ms in `init/1`
      # (deps/erlexec/src/exec.erl) to see whether its port program dies
      # immediately. Starting the app via the application controller would
      # therefore add 350ms to *every* `mix test` boot, so in test we leave
      # the app out of `applications` and let `Nest.Tools.Exec.ensure_started/0`
      # start it on the first shell command instead.
      #
      # ONLY `:test` skips the auto-start. Every other env keeps the default
      # (`runtime: true`), so the app stays in `applications` and a release
      # built in *any* env still ships it. Do not "simplify" this to a bare
      # `runtime: false` (that drops the app from releases), and do not widen
      # the exclusion past `:test` (a non-prod release would then ship without
      # `:erlexec` and the first shell command would fail).
      {:erlexec, "~> 2.0", runtime: Mix.env() != :test},
      {:mustache, "~> 0.5"},
      {:tokenizers, "~> 0.5"},
      {:exprof, "~> 0.2", only: :test},
      {:comeonin, "~> 5.4"},
      {:argon2_elixir, "~> 4.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["cmd --cd assets pnpm install"],
      "assets.build": ["cmd --cd assets pnpm build"],
      "assets.deploy": [
        "cmd --cd assets pnpm build",
        "phx.copy default",
        "phx.digest"
      ],
      "assets.test": [
        "cmd --cd assets '(pnpm vitest run --no-color --coverage --reporter=verbose) 2>&1'"
      ],
      "assets.check": [
        "cmd --cd assets pnpm biome check",
        "cmd --cd assets node lint-file-size.mjs"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo",
        # Host-dependent timeout: 5s on the fast reference host
        # ("vampire"), 15s elsewhere. See scripts/precommit-test.sh.
        # Changing this isn't an option, ever, for any reason.
        "cmd bash scripts/precommit-test.sh",
        "cmd --cd assets 'pnpm biome ci && node lint-file-size.mjs'",
        "test --cover",
        "assets.test"
      ]
    ]
  end
end
