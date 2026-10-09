defmodule Nest.Agents.Agent.TmpSpace do
  @moduledoc false
  # Scratch-directory helpers extracted from `Nest.Agents.Agent` so that
  # module stays under the 500-line credo cap.
  #
  # Each agent gets its own directory under its *space's* scratch root:
  #
  #     /tmp/nest-<BEAM ospid>/space-<space_id>/<agent-name>
  #
  # The **space** directory (`space-<space_id>`) is what `Nest.Sandbox`
  # bind-mounts at `/tmp`, so every agent in a space sees the same `/tmp`
  # and can read any sibling's scratch files. The per-agent subdirectory
  # keeps that shared root tidy and avoids filename collisions between
  # agents. `terminate/2` removes only the agent's own subdirectory.
  #
  # ## Space-directory lifecycle
  #
  # The space directory is created on demand (`mkdir_p!`) and never
  # removed by an agent: an agent's `terminate/2` deletes only its own
  # subdirectory (see `cleanup/2`). There is no clean space-lifecycle hook
  # to hang its removal off: `Nest.Spaces.archive_space/1` is reversible
  # (so deleting would be wrong) and both it and `delete_space/1` run in
  # whichever BEAM pid happens to serve the request — not necessarily the
  # pid that created the directory, since the path embeds the BEAM's
  # OS pid. The space directory is therefore left to OS `/tmp` cleanup.

  @tmp_prefix "/tmp/nest-"

  # Characters allowed verbatim in an agent's scratch-dir segment. Agent
  # names are normally slugs, but a user-supplied name is not validated
  # to be one, so everything else is percent-encoded (see `agent_dir/2`).
  @safe_segment_chars ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

  require Logger

  @doc """
  Create (on demand, idempotently) and return the agent's own scratch
  directory, `<space_dir>/<agent-name>` (the name is percent-encoded to a
  single safe path segment; see `agent_dir/2`).
  """
  @spec create(integer(), String.t()) :: String.t()
  def create(space_id, agent_name) do
    path = agent_dir(space_id, agent_name)
    File.mkdir_p!(path)
    Logger.info("Created tmp space for agent #{space_id}/#{agent_name}: #{path}")
    path
  end

  @doc """
  Remove the agent's own scratch directory, leaving the space directory
  (and every sibling's subdirectory) untouched.
  """
  @spec cleanup(integer(), String.t()) :: :ok
  def cleanup(space_id, agent_name) do
    path = agent_dir(space_id, agent_name)
    space = space_dir(space_id)

    # Backstop guard, not the protection: `agent_dir/2` already guarantees
    # a single non-dot segment (see `safe_segment/1`), so this refusal
    # branch is unreachable for any name. It is a *syntactic* check
    # (`Path.dirname/1`) and is sound only because the encoder guarantees
    # that shape; if a future caller built the path without `agent_dir/2`,
    # this would be the last line of defence against `rm_rf`-ing `/tmp`,
    # `/`, or a sibling's files.
    if String.starts_with?(path, @tmp_prefix) and Path.dirname(path) == space do
      File.rm_rf(path)
      Logger.info("Cleaned up tmp space for agent #{space_id}/#{agent_name}: #{path}")
    else
      Logger.error(
        "TmpSpace.cleanup: refusing to rm_rf a path that is not a single agent " <>
          "sub-directory: #{inspect(path)}"
      )
    end

    # NOTE: do NOT `rmdir` the space directory (or any shared parent).
    # Every Agent in a space shares one space directory, and every Agent
    # in the same BEAM shares the `nest-<OS_PID>` root. Calling `rmdir`
    # here races with a sibling agent's `mkdir_p!` during a parallel
    # `mix test`: one agent's `terminate/2` removes a parent another
    # agent's `init/1` is about to nest under, producing
    # `File.Error{reason: :enoent}` in `start_agent/1`. The parent is
    # recreated on demand by `mkdir_p!` anyway, so the cleanup gains
    # nothing and the race was a real bug. The space directory is left to
    # OS `/tmp` cleanup (see the moduledoc).
    :ok
  end

  @doc """
  The host directory bound at `/tmp` inside the sandbox: the scratch
  root shared by every agent in `space_id`.
  """
  @spec space_dir(integer()) :: String.t()
  def space_dir(space_id) do
    Path.join([@tmp_prefix <> Elixir.System.pid(), "space-#{space_id}"])
  end

  defp agent_dir(space_id, agent_name) do
    Path.join(space_dir(space_id), safe_segment(agent_name))
  end

  # Encode an agent name to a single safe path segment. This is the
  # load-bearing safety property of the scratch layout: `cleanup/2`
  # decides "is this a single agent sub-directory?" with the *syntactic*
  # check `Path.dirname(path) == space`, so an unencoded `..` would pass
  # it and `File.rm_rf("<space>/..")` would wipe the whole shared
  # `nest-<ospid>` root — every space, every agent's scratch.
  # Percent-encoding anything outside `[A-Za-z0-9_-]` (with `%` itself
  # encoded) guarantees a single non-dot segment and keeps the mapping
  # collision-free; ordinary slug-like names are unchanged. The guard in
  # `cleanup/2` is sound only because every path is built through here —
  # a caller that joined the name onto `space_dir/1` directly would
  # silently reopen the hole.
  defp safe_segment(name) do
    case URI.encode(to_string(name), &safe_segment_char?/1) do
      "" -> "%00"
      segment -> segment
    end
  end

  defp safe_segment_char?(char), do: char in @safe_segment_chars
end
