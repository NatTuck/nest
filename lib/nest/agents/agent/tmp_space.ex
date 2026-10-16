defmodule Nest.Agents.Agent.TmpSpace do
  @moduledoc false
  # Scratch-directory helpers extracted from `Nest.Agents.Agent` so that
  # module stays under the 500-line credo cap.
  #
  # Each agent gets its own directory under its *space's* scratch root. The
  # root depends on the space's sandbox backend, because the backend decides
  # what the agent's `/tmp` is (see `Nest.Sandbox.Backend`):
  #
  #     bwrap / docker:  /tmp/nest-<BEAM ospid>/space-<space_id>/<agent-name>
  #     none:            /tmp/<agent-name>
  #
  # The **space** directory (`space-<space_id>`) is what `Nest.Sandbox`
  # bind-mounts at `/tmp`, so every agent in a space sees the same `/tmp`
  # and can read any sibling's scratch files. The per-agent subdirectory
  # keeps that shared root tidy and avoids filename collisions between
  # agents. `terminate/2` removes only the agent's own subdirectory.
  #
  # ## The `"none"` root is the host's real `/tmp`
  #
  # A `"none"` space runs bare commands on the host, so there is no bind to
  # place and no per-space root to isolate: the agent's `/tmp/<agent-name>` is
  # *literally* the host's `/tmp/<agent-name>`, which is what makes the
  # agent-visible spelling identical on every backend. The consequence is that
  # two `"none"` spaces share one namespace of agent names — `/tmp/<name>` is
  # one directory whoever owns it — so a `"none"` agent may not take a name a
  # live agent in another `"none"` space is using (see
  # `Nest.Agents.Agent.PreSpawn.pre_spawn/1` and
  # `Nest.Agents.Supervisor.existing_names_for_space/1`).
  #
  # ## Space-directory lifecycle
  #
  # The space directory is created on demand (`mkdir_p!`) and never
  # removed by an agent: an agent's `terminate/2` deletes only its own
  # subdirectory (see `cleanup/3`). There is no clean space-lifecycle hook
  # to hang its removal off: `Nest.Spaces.archive_space/1` is reversible
  # (so deleting would be wrong) and both it and `delete_space/1` run in
  # whichever BEAM pid happens to serve the request — not necessarily the
  # pid that created the directory, since the path embeds the BEAM's
  # OS pid. The space directory is therefore left to OS `/tmp` cleanup.

  alias Nest.Sandbox.Paths

  @tmp_prefix "/tmp/nest-"

  # The root a `"none"` space's agents live under: the host's real `/tmp`.
  # `Paths.scratch_root/1` refuses this value as a *bind* source (binding it
  # would be a sandbox escape) — which is exactly why a `"none"` space has no
  # bind and stages its command transcripts through `Paths.stage_dir(nil)`.
  @none_root Paths.sandbox_root()

  # An agent name must be usable verbatim as a single filename component:
  # letters, digits, `_` and `-` only. No `/` (would nest a path), no `.`
  # (a `..` component would escape the space dir), no whitespace, no
  # control characters.
  #
  # This is the same rule `PersistedAgent.changeset/2` enforces at the DB
  # boundary, re-checked here because this module is what turns a name
  # into a path it later `rm_rf`s. It is the local backstop for a row that
  # predates the changeset rule (see the `sanitize_agent_names`
  # migration): without it, `cleanup/3` on a name of `..` would build
  # `<space>/..` and wipe the whole shared `nest-<ospid>` root — every
  # space, every agent's scratch.
  @name_format ~r/\A[A-Za-z0-9_-]+\z/

  require Logger

  @doc """
  Create (on demand, idempotently) and return the agent's own scratch
  directory, `<space_dir>/<agent-name>`.

  Raises `ArgumentError` for a name that is not a single safe path
  component (see `agent_dir/3`). `PersistedAgent.changeset/2` enforces the
  same rule on every insert, so a name that came out of the DB always
  passes; a raise here means a caller skipped that boundary, and failing
  loudly is what keeps the scratch layout sound.
  """
  @spec create(integer(), String.t(), String.t()) :: String.t()
  def create(space_id, agent_name, backend) do
    path = agent_dir(space_id, agent_name, backend)
    File.mkdir_p!(path)
    Logger.info("Created tmp space for agent #{space_id}/#{agent_name}: #{path}")
    path
  end

  @doc """
  Remove the agent's own scratch directory, leaving the space directory
  (and every sibling's subdirectory) untouched.
  """
  @spec cleanup(integer(), String.t(), String.t()) :: :ok
  def cleanup(space_id, agent_name, backend) do
    if single_segment?(agent_name) do
      path = agent_dir(space_id, agent_name, backend)
      File.rm_rf(path)
      Logger.info("Cleaned up tmp space for agent #{space_id}/#{agent_name}: #{path}")
    else
      # Refuse rather than raise: `cleanup/3` runs from `terminate/2`, and
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

  `cleanup/3` for a caller that holds the key rather than the two parts — the
  shell-jobs manager's `drop_agent/3`, which removes an agent's scratch after
  it has stopped the agent's jobs. A key that is not `{integer, binary}` is
  ignored rather than routed to `cleanup/3`: `{:unknown, :unknown}` and
  `{nil, nil}` are real keys in that manager, and neither names a directory.

  `backend` is the dropped agent's backend, because it decides which root the
  scratch directory is under (see the moduledoc). The shell-jobs manager keeps
  it on the agent's tracked record, so this needs no DB read.

  The removal is tied to an **incarnation**: `owner` is the pid of the agent
  being dropped, and the call refuses while a *different* live agent is
  registered under the key. The scratch path is derived from the key, so two
  incarnations of the same agent share it; a monitor for a previous incarnation
  can fire after the next one has started (the manager's `:DOWN` for a pid it
  tracked), and removing the directory then would delete a live agent's scratch
  out from under it. `owner` may be `nil` for a caller with no incarnation to
  name, in which case *any* live owner refuses. The registry is the authority on
  which incarnation, if any, owns the key.

  **Residual window, not closed.** The guard is check-then-act: it reads the
  registry, then `cleanup/3` does the `rm_rf`, and a new incarnation can slip in
  between — `Agent.start_link/1` registers the name before `init/1` runs
  (`agent.ex`'s `Registry.via_tuple/2`), and `init/1` then `mkdir_p!`s the
  directory (`Init.build_state/2` → `create/3`). If the lookup returns `:error`,
  the manager is preempted, that incarnation registers and creates, and the
  manager resumes, it removes the *new* agent's scratch. The window is one
  preemption gap (a registry lookup, a regex match and a `Path.join`; none
  yields), and the consequence is a scratch-less agent — nothing re-creates the
  directory. Closing it needs the create to be ordered after any pending delete
  for the key (or an incarnation-unique path), not a better-timed check.
  """
  @spec cleanup_agent_key(term(), pid() | nil, String.t()) :: :ok
  def cleanup_agent_key({space_id, name} = key, owner, backend)
      when is_integer(space_id) and is_binary(name) do
    if live_other_owner?(key, owner), do: :ok, else: cleanup(space_id, name, backend)
  end

  def cleanup_agent_key(_agent_key, _owner, _backend), do: :ok

  defp live_other_owner?({space_id, name}, owner) do
    case Nest.Agents.Registry.lookup(space_id, name) do
      {:ok, pid} -> pid != owner and Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  The host directory bound at `/tmp` inside the sandbox: the scratch
  root shared by every agent in `space_id`.

  For a `"none"` space that is the host's real `/tmp` (nothing is bound), so
  `/tmp/<agent-name>` is literally true there too.
  """
  @spec space_dir(integer(), String.t()) :: String.t()
  def space_dir(_space_id, "none"), do: @none_root

  # Every backend that binds anything gets its own per-space root. The clause is
  # open rather than listing `bwrap` and `docker`, because a backend string this
  # build does not know is refused when a command runs
  # (`Nest.Sandbox.Backend.resolve/1`) and this module is also reached from
  # `terminate/2`, where raising would lose the cleanup.
  def space_dir(space_id, _backend) do
    Path.join([@tmp_prefix <> Elixir.System.pid(), "space-#{space_id}"])
  end

  @doc """
  The agent's own scratch directory: the bare name under the space dir.

  Public because it is the one derivation of that path, and the tests and the
  name boundary both need it without creating anything.
  """
  @spec agent_dir(integer(), String.t(), String.t()) :: String.t()
  def agent_dir(space_id, agent_name, backend) do
    if single_segment?(agent_name) do
      Path.join(space_dir(space_id, backend), agent_name)
    else
      raise ArgumentError,
            "refusing to build a scratch path for an unsafe agent name: " <>
              inspect(agent_name)
    end
  end

  defp single_segment?(name), do: is_binary(name) and String.match?(name, @name_format)
end
