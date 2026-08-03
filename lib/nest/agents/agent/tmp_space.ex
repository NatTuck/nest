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

    # NOTE: do NOT `rmdir` the shared parent `tmp/nest-<OS_PID>`.
    # Every Agent in the same BEAM shares one OS pid, so the parent
    # is process-global, not per-agent. Calling `rmdir` here races
    # with a sibling agent's `mkdir_p!` during a parallel `mix test`:
    # one's `terminate/2` removes the parent another agent's
    # `init/1` is about to nest under, producing
    # `File.Error{reason: :enoent}` in `start_agent/1`. The parent is
    # recreated on demand by `mkdir_p!` anyway, so the cleanup gains
    # nothing and the race was a real bug. `/tmp` is wiped on system
    # cleanup, so leaving the parent in place has no lifecycle cost.
  end
end
