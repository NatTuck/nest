defmodule Mix.Tasks.Nest.RepairMessages do
  use Mix.Task

  @shortdoc "Repair persisted message sequences (tool pairing / alternation)"

  @moduledoc """
  Repairs persisted message sequences that the live path left in an
  invalid state (an unanswered assistant `tool_use`, or two
  consecutive same-role wire messages), by inserting synthetic
  `is_error` tool results / acknowledgements and renumbering the
  affected rows (including shifted clones).

  Default is a dry run. Pass `--apply` to write.

      mix nest.repair_messages --space clever-raven
      mix nest.repair_messages --space clever-raven --apply
      mix nest.repair_messages --all --verbose
      mix nest.repair_messages --all --apply

  Exactly one of `--space <name>` or `--all` is required. The command
  exits non-zero when a dry run finds violations or when an applied
  run still finds residual violations. Live agents must be restarted
  afterwards: their in-memory sequences are not touched.
  """

  alias Nest.Persistence.MessageRepair

  @switches [space: :string, all: :boolean, apply: :boolean, verbose: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, target, opts} -> execute(target, opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc """
  Parse command-line `args` into `{:ok, target, opts}` or
  `{:error, message}`. Pure, so the CLI contract is unit-testable
  without starting the application.
  """
  @spec parse_args([String.t()]) ::
          {:ok, MessageRepair.target(), keyword()} | {:error, String.t()}
  def parse_args(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    validate(parsed, invalid)
  end

  defp validate(_parsed, [_ | _] = invalid) do
    names = Enum.map_join(invalid, ", ", fn {name, _} -> name end)
    {:error, "unknown option(s): " <> names}
  end

  defp validate(parsed, []) do
    case {parsed[:space], parsed[:all]} do
      {space, true} when is_binary(space) ->
        {:error, "use either --space <name> or --all, not both"}

      {space, _} when is_binary(space) ->
        {:ok, {:space, space}, flags(parsed)}

      {nil, true} ->
        {:ok, :all, flags(parsed)}

      _ ->
        {:error, "specify --space <name> or --all"}
    end
  end

  defp flags(parsed), do: [apply: parsed[:apply] == true, verbose: parsed[:verbose] == true]

  defp execute(target, opts) do
    case MessageRepair.run(target, opts) do
      {:ok, plan, agents} ->
        Mix.shell().info(MessageRepair.format_report(plan, agents, opts[:verbose]))
        enforce_exit(plan, opts)

      {:error, reason} ->
        Mix.raise("repair failed: #{inspect(reason)}")
    end
  end

  defp enforce_exit(plan, opts) do
    apply? = Keyword.get(opts, :apply, false)

    if exit_status(plan, apply?) do
      Mix.raise(exit_message(apply?))
    end

    :ok
  end

  defp exit_status(plan, true), do: MessageRepair.residual?(plan)
  defp exit_status(plan, false), do: MessageRepair.violations?(plan)

  defp exit_message(true), do: "repair applied, but residual violations remain (see report above)"
  defp exit_message(false), do: "violations found; re-run with --apply to repair"
end
