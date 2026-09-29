defmodule Mix.Tasks.Nest.CompactAgent do
  use Mix.Task

  @shortdoc "Offline-compact one agent's persisted history"

  @moduledoc """
  Offline compaction of a single agent's persisted message history.

  Loads the agent's full sequence, summarizes the active prefix (a
  bounded, iterative fold that handles histories larger than the
  model's context window), and writes a compaction marker plus a fresh
  system message and summary. Default is a dry run; pass `--apply` to
  write.

      mix nest.compact_agent clever-raven/happy-otter
      mix nest.compact_agent clever-raven/happy-otter --apply
      mix nest.compact_agent clever-raven/happy-otter --apply --model provider/model
      mix nest.compact_agent clever-raven/happy-otter --apply --focus "keep the API decisions"

  This is a recovery tool: it shares no code with the live compaction
  pipeline and still works when the active history already exceeds the
  model's context limit. The affected agent must be restarted
  afterwards — its in-memory state is not touched. Refuses to run on a
  sequence that fails the wire preflight unless `--force` is given
  (run `mix nest.repair_messages` first).
  """

  alias Nest.Persistence.AgentCompaction

  @switches [
    apply: :boolean,
    force: :boolean,
    verbose: :boolean,
    model: :string,
    focus: :string,
    max_calls: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case parse_args(args) do
      {:ok, target, opts} -> execute(target, opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc """
  Parse command-line `args` into `{:ok, {space, name}, opts}` or
  `{:error, message}`. Pure, so the CLI contract is unit-testable
  without starting the application.
  """
  @spec parse_args([String.t()]) ::
          {:ok, AgentCompaction.target(), keyword()} | {:error, String.t()}
  def parse_args(args) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: @switches)

    with :ok <- validate_invalid(invalid),
         {:ok, target} <- parse_target(rest) do
      {:ok, target, flags(parsed)}
    end
  end

  defp validate_invalid([]), do: :ok

  defp validate_invalid(invalid) do
    names = Enum.map_join(invalid, ", ", fn {name, _} -> name end)
    {:error, "unknown option(s): " <> names}
  end

  defp parse_target([target]) do
    case String.split(target, "/", parts: 2) do
      [space, name] when space != "" and name != "" ->
        {:ok, {space, name}}

      _ ->
        {:error, "expected a {space}/{name} target, got: #{inspect(target)}"}
    end
  end

  defp parse_target([]), do: {:error, "specify a target: {space}/{name}"}
  defp parse_target(other), do: {:error, "unexpected arguments: #{Enum.join(other, " ")}"}

  defp flags(parsed) do
    [
      apply: parsed[:apply] == true,
      force: parsed[:force] == true,
      verbose: parsed[:verbose] == true,
      model: parsed[:model],
      focus: parsed[:focus],
      max_calls: parsed[:max_calls]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)
  end

  defp execute(target, opts) do
    case AgentCompaction.run(target, opts) do
      {:ok, plan, summary} ->
        Mix.shell().info(AgentCompaction.format_report(plan, Keyword.get(opts, :apply, false)))
        if summary, do: Mix.shell().info("\nSummary:\n#{summary}")
        :ok

      {:error, reason} ->
        Mix.raise("compact failed: #{format_reason(reason)}")
    end
  end

  defp format_reason({:space_not_found, name}),
    do: "space not found: #{name}"

  defp format_reason({:agent_not_found, name}),
    do: "agent not found: #{name}"

  defp format_reason({:sequence_violations, message}),
    do:
      "message sequence fails the wire preflight (run `mix nest.repair_messages` " <>
        "first, or pass --force): #{message}"

  defp format_reason(:nothing_to_compact),
    do: "nothing to compact (the active history has no conversation)"

  defp format_reason(other), do: inspect(other)
end
