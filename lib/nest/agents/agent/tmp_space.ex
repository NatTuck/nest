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

  # An agent name must be usable verbatim as a single filename component:
  # letters, digits, `_` and `-` only. No `/` (would nest a path), no `.`
  # (a `..` component would escape the space dir), no whitespace, no
  # control characters.
  #
  # This is the same rule `PersistedAgent.changeset/2` enforces at the DB
  # boundary, re-checked here because this module is what turns a name
  # into a path it later `rm_rf`s. It is the local backstop for a row that
  # predates the changeset rule (see the `sanitize_agent_names`
  # migration): without it, `cleanup/2` on a name of `..` would build
  # `<space>/..` and wipe the whole shared `nest-<ospid>` root — every
  # space, every agent's scratch.
  @name_format ~r/\A[A-Za-z0-9_-]+\z/

  require Logger

  @doc """
  Create (on demand, idempotently) and return the agent's own scratch
  directory, `<space_dir>/<agent-name>`.

  Raises `ArgumentError` for a name that is not a single safe path
  component (see `agent_dir/2`). `PersistedAgent.changeset/2` enforces the
  same rule on every insert, so a name that came out of the DB always
  passes; a raise here means a caller skipped that boundary, and failing
  loudly is what keeps the scratch layout sound.
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
    if single_segment?(agent_name) do
      path = agent_dir(space_id, agent_name)
      File.rm_rf(path)
      Logger.info("Cleaned up tmp space for agent #{space_id}/#{agent_name}: #{path}")
    else
      # Refuse rather than raise: `cleanup/2` runs from `terminate/2`, and
      # a name that cannot be a single directory component must never turn
      # into an `rm_rf` of `/tmp`, `/`, or a sibling's files.
      Logger.error(
        "TmpSpace.cleanup: refusing to rm_rf for an unsafe agent name: " <>
          inspect(agent_name)
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
  Remove the scratch directory for an agent key, `{space_id, name}`.

  `cleanup/2` for a caller that holds the key rather than the two parts — the
  shell-jobs manager's `drop_agent/3`, which removes an agent's scratch after
  it has stopped the agent's jobs. A key that is not `{integer, binary}` is
  ignored rather than routed to `cleanup/2`: `{:unknown, :unknown}` and
  `{nil, nil}` are real keys in that manager, and neither names a directory.

  The removal is tied to an **incarnation**: `owner` is the pid of the agent
  being dropped, and the call refuses while a *different* live agent is
  registered under the key. The scratch path is derived from the key, so two
  incarnations of the same agent share it; a monitor for a previous incarnation
  can fire after the next one has started (the manager's `:DOWN` for a pid it
  tracked), and removing the directory then would delete a live agent's scratch
  out from under it. `owner` may be `nil` for a caller with no incarnation to
  name, in which case *any* live owner refuses. The registry is the authority on
  which incarnation, if any, owns the key.
  """
  @spec cleanup_agent_key(term(), pid() | nil) :: :ok
  def cleanup_agent_key({space_id, name} = key, owner)
      when is_integer(space_id) and is_binary(name) do
    if live_other_owner?(key, owner), do: :ok, else: cleanup(space_id, name)
  end

  def cleanup_agent_key(_agent_key, _owner), do: :ok

  defp live_other_owner?({space_id, name}, owner) do
    case Nest.Agents.Registry.lookup(space_id, name) do
      {:ok, pid} -> pid != owner and Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  The host directory bound at `/tmp` inside the sandbox: the scratch
  root shared by every agent in `space_id`.
  """
  @spec space_dir(integer()) :: String.t()
  def space_dir(space_id) do
    Path.join([@tmp_prefix <> Elixir.System.pid(), "space-#{space_id}"])
  end

  # The agent's own directory: the bare name under the space dir. The name
  # is validated rather than encoded — an unusable name is refused at the
  # DB boundary instead of being rewritten into a path the user never
  # chose, and the segment stays a single non-dot component (which is what
  # makes the `rm_rf` in `cleanup/2` safe).
  defp agent_dir(space_id, agent_name) do
    if single_segment?(agent_name) do
      Path.join(space_dir(space_id), agent_name)
    else
      raise ArgumentError,
            "refusing to build a scratch path for an unsafe agent name: " <>
              inspect(agent_name)
    end
  end

  defp single_segment?(name), do: is_binary(name) and String.match?(name, @name_format)
end
