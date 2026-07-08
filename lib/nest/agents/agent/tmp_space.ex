defmodule Nest.Agents.Agent.TmpSpace do
  @moduledoc false
  # Tmp directory helpers extracted from `Nest.Agents.Agent`
  # so that module stays under the 500-line credo cap. Each
  # agent gets `/tmp/nest-<VMPID>/agent-<id>` for tool output
  # scratch space; `terminate/2` cleans it up.

  require Logger

  @doc false
  def create(agent_id) do
    tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"
    File.mkdir_p!(tmp_path)
    Logger.info("Created tmp space for agent #{agent_id}: #{tmp_path}")
    tmp_path
  end

  @doc false
  def cleanup(agent_id) do
    tmp_path = "/tmp/nest-#{Elixir.System.pid()}/agent-#{agent_id}"
    File.rm_rf(tmp_path)
    Logger.info("Cleaned up tmp space for agent #{agent_id}: #{tmp_path}")

    # Try to clean up parent directory if empty
    parent_path = Path.dirname(tmp_path)

    case File.ls(parent_path) do
      {:ok, []} ->
        File.rmdir(parent_path)
        Logger.info("Cleaned up empty parent directory: #{parent_path}")

      _ ->
        :ok
    end
  end
end
