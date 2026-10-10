defmodule Mix.Tasks.Nest.Timeline do
  use Mix.Task

  @shortdoc "Render a human digest of a recorded timeline run"

  @moduledoc """
  Renders the human digest of a run recorded by `Nest.Timeline` (W5's
  observation kit). See `Nest.Timeline.Digest` for the output shape.

      mix nest.timeline
      mix nest.timeline --run notes/usage-runs/20261009-134512-12345
      mix nest.timeline --space 7 --agent coordinator

  Without `--run`, the newest directory under the timeline base dir
  (`notes/usage-runs/` by default) is used. `--space` and `--agent`
  filter the events.

  The task only reads files, so it does not start the application — it
  works while the server that recorded the run is still running, and
  after it is gone. Recording itself is off by default: start the server
  with `NEST_TIMELINE=1` to produce a run.
  """

  alias Nest.Timeline
  alias Nest.Timeline.Digest

  @switches [run: :string, space: :string, agent: :string]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      {:ok, opts} -> print(opts)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc """
  Parse command-line `args` into `{:ok, opts}` or `{:error, message}`.

  Pure, so the CLI contract is unit-testable without shelling out.
  """
  @spec parse_args([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse_args(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)

    case invalid do
      [] ->
        {:ok, parsed}

      _ ->
        {:error, "unknown option(s): " <> Enum.map_join(invalid, ", ", fn {name, _} -> name end)}
    end
  end

  defp print(opts) do
    case opts[:run] || Timeline.latest_run() do
      nil -> Mix.shell().info(no_runs_message())
      dir -> Mix.shell().info(Digest.render(dir, space: opts[:space], agent: opts[:agent]))
    end
  end

  defp no_runs_message do
    "No runs found under #{Timeline.base_dir()}/. Start the server with " <>
      "NEST_TIMELINE=1 to record one."
  end
end
