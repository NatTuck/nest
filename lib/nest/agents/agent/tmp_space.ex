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
  # ## A `"none"` scratch carries Nest's own marker
  #
  # `/tmp/<name>` is not distinguishable from the host's own `/tmp` entries by
  # its shape: the name is client- and model-controlled, `@name_format` allows
  # `nest-4`, `X11-unix` and `snap-private-tmp`, and all three are real things to
  # find in a `/tmp`. An `rm_rf` on one of them would take another BEAM's whole
  # scratch root (every space's offloads, shell-job logs and `.nest` tmp mounts)
  # or a host directory Nest never owned.
  #
  # So `create/3` writes `#{@marker}` into a `"none"` agent's scratch, and every
  # removal requires it: `cleanup/3`, `remove_stale/3`. A directory without the
  # marker is never removed. That is the safe direction, and it has two honest
  # residuals: a pre-existing `/tmp/X11-unix`, or a `"none"` scratch created
  # before this change, is left alone forever; and an agent that deletes its own
  # marker leaves a stale directory behind. Only `"none"` needs the marker —
  # a bwrap or docker scratch is under `nest-<BEAM pid>/space-<id>/`, which
  # already says whose it is.
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

  alias Nest.Sandbox.{Mounts, Paths}

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

  # What a `"none"` agent's scratch directory carries to say it is Nest's. See
  # the moduledoc.
  @marker ".nest-scratch"

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
    write_marker(path, backend)
    Logger.info("Created tmp space for agent #{space_id}/#{agent_name}: #{path}")
    path
  end

  # A `"none"` scratch is the host's own `/tmp/<name>`, so it has to say it is
  # Nest's before anything will remove it (see the moduledoc). The other backends
  # need nothing: their paths carry `nest-<BEAM pid>/space-<id>`.
  defp write_marker(path, "none"), do: File.write!(Path.join(path, @marker), "")
  defp write_marker(_path, _backend), do: :ok

  @doc """
  Remove the agent's own scratch directory, leaving the space directory
  (and every sibling's subdirectory) untouched.
  """
  @spec cleanup(integer(), String.t(), String.t()) :: :ok
  def cleanup(space_id, agent_name, backend) do
    if single_segment?(agent_name) do
      remove(space_id, agent_name, backend, :cleanup)
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
  Remove a stopped agent's stale scratch directory, if it is safe to.

  `PreSpawn.pre_spawn/1` calls this when an agent takes a name that no *live*
  agent holds, so that a fresh agent starts from a fresh scratch instead of
  inheriting a stopped one's files. The caller has already established that no
  live agent owns the name, so the only question left here is whether the
  directory is Nest's to remove at all (`remove/4`).

  Returns `:ok` whether or not anything was removed: this is cleanup, and the
  caller has nothing to do about a refusal.
  """
  @spec remove_stale(integer(), String.t(), String.t()) :: :ok
  def remove_stale(space_id, agent_name, backend) do
    # A name that cannot be a path component is the row changeset's refusal to
    # make; there is no directory of that name, and nothing here may raise.
    if single_segment?(agent_name), do: remove(space_id, agent_name, backend, :stale)
    :ok
  end

  @doc """
  The mounts a prompt for `name` is composed through.

  Composing a prompt *runs* the sandbox — `Nest.Agents.Agent.SystemPrompt` reads
  `AGENTS.md` through it — so the mounts have to be the agent's real ones, and
  the scratch directory has to be named even though it may not exist yet:
  `Nest.Sandbox.Backend.Docker.command/3` can only stage a script the container
  can reach through the scratch bind, and without it the read fails as a
  not-found that the prompt then swallows. The directory is created on demand by
  `Nest.Sandbox.Mounts.ensure_scratch!/1` before anything is staged.

  `nil` scratch for a name that cannot be a path component: such an agent is
  refused by its own changeset, and nothing composes a prompt for it.
  """
  @spec prompt_mounts(String.t() | nil, integer(), String.t(), String.t()) :: Mounts.t()
  def prompt_mounts(workspace, space_id, name, backend) do
    scratch = if single_segment?(name), do: agent_dir(space_id, name, backend)
    Mounts.new(workspace, scratch, backend, space_id)
  end

  # The one place a scratch directory is removed, with both guards a `rm_rf`
  # needs. Each refusal leaves a directory behind rather than removing the wrong
  # one.
  #
  # `reason` only shapes the log line: `:cleanup` is an agent stopping,
  # `:stale` is a new agent taking a name a stopped one held.
  defp remove(space_id, agent_name, backend, reason) do
    path = agent_dir(space_id, agent_name, backend)

    cond do
      # Nothing there: the agent never created one, or something already took it.
      # Not notable, and not something to report.
      not File.dir?(path) ->
        :ok

      not marked?(path, backend) ->
        Logger.error(
          "TmpSpace.#{reason}: refusing to rm_rf #{path}: it is not a Nest scratch directory"
        )

      held_by_another_none_space?(space_id, agent_name, backend) ->
        Logger.info(
          "TmpSpace.#{reason}: leaving #{path}: a live agent in another space uses the same name"
        )

      true ->
        File.rm_rf(path)
        Logger.info("Cleaned up tmp space for agent #{space_id}/#{agent_name}: #{path}")
    end

    :ok
  end

  # A `"none"` scratch is the host's own `/tmp/<name>`, so the marker is the only
  # thing that says Nest owns it. Every other backend's scratch sits under
  # `nest-<BEAM pid>/space-<id>/`, which already says so.
  defp marked?(_path, backend) when backend != "none", do: true
  defp marked?(path, "none"), do: File.exists?(Path.join(path, @marker))

  # Two `"none"` spaces share one `/tmp`, so the same name can be live in both:
  # a space's `x` can stop, another space take the name, and the first be
  # rehydrated — the on-demand restart path is deliberately not gated by the
  # creation boundary. Removing the directory then would delete a live agent's
  # scratch. Registry-only, because this runs from `terminate/2`, where a DB read
  # is not available; over-refusing leaves a stale directory, which is harmless.
  defp held_by_another_none_space?(_space_id, _name, backend) when backend != "none", do: false

  defp held_by_another_none_space?(space_id, name, "none") do
    Enum.any?(Nest.Agents.Registry.list_all(), fn {other_space_id, other_name} ->
      other_name == name and other_space_id != space_id
    end)
  rescue
    # The registry is gone (application shutdown). Refusing is the safe
    # direction: a stale directory, not a live agent's scratch.
    ArgumentError -> true
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
