defmodule Nest.Agents.Agent.TmpSpace do
  @moduledoc false
  # Tmp directory helpers extracted from `Nest.Agents.Agent`
  # so that module stays under the 500-line credo cap. Each
  # agent gets `/tmp/nest-<VMPID>/agent-<id>` for tool output
  # scratch space; `terminate/2` cleans it up.

  @tmp_prefix "/tmp/nest-"

  require Logger

  @doc false
  def create(agent_id) do
    tmp_path = "#{@tmp_prefix}#{Elixir.System.pid()}/agent-#{agent_id}"
    File.mkdir_p!(tmp_path)
    Logger.info("Created tmp space for agent #{agent_id}: #{tmp_path}")
    tmp_path
  end

  @doc false
  def cleanup(agent_id) do
    tmp_path = "#{@tmp_prefix}#{Elixir.System.pid()}/agent-#{agent_id}"

    # Guard: `rm_rf` must only run on paths under the known prefix.
    # A string-handling bug that produces an unexpected prefix should
    # log an error instead of, say, wiping `/tmp` or `/`.
    if String.starts_with?(tmp_path, @tmp_prefix) do
      File.rm_rf(tmp_path)
      Logger.info("Cleaned up tmp space for agent #{agent_id}: #{tmp_path}")
    else
      Logger.error(
        "TmpSpace.cleanup: refusing to rm_rf path with unexpected prefix: " <>
          "#{inspect(tmp_path)}"
      )
    end

    parent_path = Path.dirname(tmp_path)

    if String.starts_with?(parent_path, @tmp_prefix) do
      case File.rmdir(parent_path) do
        :ok ->
          Logger.info("Cleaned up empty parent directory: #{parent_path}")

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.debug(
            "TmpSpace.cleanup: parent rmdir returned #{inspect(reason)} for " <>
              "#{parent_path}; leaving directory in place."
          )
      end
    end
  end
end
