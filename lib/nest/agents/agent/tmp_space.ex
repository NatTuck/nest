defmodule Nest.Agents.Agent.TmpSpace do
  @moduledoc false
  # Scratch-directory helpers extracted from `Nest.Agents.Agent` so that
  # module stays under the 500-line credo cap.
  #
  # Each agent gets its own directory under its *space's* scratch root. The
  # root depends on the space's sandbox backend, because the backend decides
  # what the agent's `/tmp` is (see `Nest.Sandbox.Backend`):
  #
  #     bwrap:   /tmp/nest-<BEAM ospid>/space-<space_id>/<agent-name>
  #     docker:  /tmp/<agent-name>       (a path inside the container)
  #     none:    /tmp/<agent-name>       (the host's real /tmp)
  #
  # The **space** directory (`space-<space_id>`) is what `Nest.Sandbox` binds at
  # `/tmp` under bwrap, so every agent in a space sees the same `/tmp` and can
  # read any sibling's scratch files. The per-agent subdirectory keeps that
  # shared root tidy and avoids filename collisions between agents.
  # `terminate/2` removes only the agent's own subdirectory.
  #
  # ## Two backends whose scratch is not a directory on the host
  #
  # A `"none"` space runs bare commands on the host, so there is no bind to
  # place and no per-space root to isolate: the agent's `/tmp/<agent-name>` is
  # *literally* the host's `/tmp/<agent-name>`, which is what makes the
  # agent-visible spelling identical on every backend.
  #
  # A `"docker"` space's `/tmp` is the *container's* own, so `/tmp/<agent-name>`
  # names a path in the container: nothing on the host may create or write it
  # (`Nest.Sandbox.Mounts.host_scratch?/1`), and the container makes it, in the
  # command that runs (see `Nest.Sandbox.Backend.Docker`). Everything this module
  # does to a scratch directory is therefore a no-op for `"docker"` — `create/3`
  # only names the path, and neither removal has anything to remove — which is
  # the same shape as the `"none"` root, one level further away.
  #
  # ## Two `"none"` spaces share one namespace of agent names
  #
  # Because a `"none"` scratch is the host's own `/tmp/<name>`, one directory is
  # one name whoever owns it: a `"none"` agent may not take a name a live agent
  # in another `"none"` space is using (see `Nest.Agents.Agent.PreSpawn.pre_spawn/1`
  # and `Nest.Agents.Supervisor.existing_names_for_space/1`).
  #
  # ## A `"none"` scratch carries Nest's own marker
  #
  # `/tmp/<name>` is not distinguishable from the host's own `/tmp` entries by
  # its shape: the name is client- and model-controlled, `Nest.Name` allows
  # `nest-4` and `snap-private-tmp`, and both are real things to find in a
  # `/tmp`. An `rm_rf` on one of them would take another BEAM's whole
  # scratch root (every space's offloads, shell-job logs and `.nest` tmp mounts)
  # or a host directory Nest never owned.
  #
  # So `create/3` writes `#{@marker}` into a `"none"` agent's scratch, and every
  # removal requires it: `cleanup/3`, `remove_stale/3`. A directory without the
  # marker is never removed, and `create/3` will not adopt one either — it raises
  # rather than stamp a marker into something that is not Nest's, which is what
  # would otherwise hand the next `cleanup/3` a licence to delete it. The name
  # boundary refuses such a name before any of that (`PreSpawn.pre_spawn/1`'s
  # `{:scratch_path_taken, path}`), and this raise is the backstop for a caller
  # that skipped the boundary.
  #
  # Two honest residuals: a `"none"` scratch created before this change has no
  # marker and is therefore never removed (and its name cannot be reused, because
  # `create/3` will not adopt it) — clear it by hand; and an agent that deletes
  # its own marker leaves a directory in the same state. Only `"none"` needs the
  # marker — a bwrap scratch is under `nest-<BEAM pid>/space-<id>/`, which
  # already says whose it is, and a docker scratch is not on the host at all.
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

  # The `/tmp` spelling inside the sandbox. It is also the directory itself for
  # the two backends whose `/tmp` *is* their scratch root — the host's own under
  # `"none"`, the container's own under `"docker"` — which is why those two need
  # no bind to place the agent's directory and why the spelling and the
  # directory coincide for them. `Paths.scratch_root/1` refuses this value as a
  # *bind* source (binding the host's `/tmp` would be a sandbox escape), which
  # is exactly why a `"none"` space has no bind and stages its command
  # transcripts through `Paths.stage_dir(nil)`.
  @sandbox_tmp Paths.sandbox_root()

  # An agent name must be usable verbatim as a single filename component:
  # letters, digits, `_` and `-` only. No `/` (would nest a path), no `.`
  # (a `..` component would escape the space dir), no whitespace, no
  # control characters.
  #
  # This is `Nest.Name` — the same rule `PersistedAgent.changeset/2` enforces at
  # the DB boundary, read from its one home rather than spelled again,
  # re-checked here because this module is what turns a name into a path it
  # later `rm_rf`s. It is the local backstop for a row that predates the
  # changeset rule (see the name migrations): without it, `cleanup/3` on a name
  # of `..` would build `<space>/..` and wipe the whole shared `nest-<ospid>`
  # root — every space, every agent's scratch.

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
  def create(space_id, agent_name, "docker") do
    # A docker scratch is a path *inside the container*. Making it here would
    # create a host directory at the same spelling that the container could never
    # see, so this only names it (and validates the name, as `agent_dir/3` does);
    # the container makes it, in the command that runs.
    agent_dir(space_id, agent_name, "docker")
  end

  def create(space_id, agent_name, backend) do
    path = agent_dir(space_id, agent_name, backend)

    # A `"none"` scratch is the host's own `/tmp/<name>`, so `mkdir_p!` would
    # silently *adopt* whatever is already there — including exactly the
    # directories the marker exists to protect (another BEAM's `nest-<pid>`, a
    # host `snap-private-tmp`). Stamping the marker into one would hand the next
    # `cleanup/3` a licence to delete it, so refuse instead. A directory Nest
    # marked earlier still re-opens idempotently, which is what re-creating a
    # stopped agent's scratch needs.
    if claimable?(path, backend) do
      File.mkdir_p!(path)
      write_marker(path, backend)
      Logger.info("Created tmp space for agent #{space_id}/#{agent_name}: #{path}")
      path
    else
      raise ArgumentError,
            "refusing to use #{inspect(path)} as a scratch directory: " <>
              "it exists and is not Nest's"
    end
  end

  @doc """
  Write Nest's scratch marker into `path`.

  `create/3` does this as part of creating the directory. This is for the one
  other creator — `Nest.Sandbox.Mounts.ensure_scratch!/1`, which stages a
  command's transcript and so has to make the directory it stages into: a
  `"none"` scratch it made without the marker would be one no later `cleanup/3`
  could ever remove (see the moduledoc).
  """
  @spec mark!(String.t(), String.t()) :: :ok
  def mark!(path, backend), do: write_marker(path, backend)

  # A `"none"` scratch is the host's own `/tmp/<name>`, so it has to say it is
  # Nest's before anything will remove it (see the moduledoc). The other backends
  # need nothing: their paths carry `nest-<BEAM pid>/space-<id>`.
  defp write_marker(path, "none"), do: File.write!(Path.join(path, @marker), "")
  defp write_marker(_path, _backend), do: :ok

  @doc """
  Whether `create/3` may use `path` as a scratch directory: it is free, or
  already carries Nest's marker.

  `false` means something is there that Nest did not put there. The name boundary
  refuses that case by name (`PreSpawn.pre_spawn/1`'s
  `{:scratch_path_taken, path}`); this is the same question, for the callers that
  have to ask it without going through the boundary.
  """
  @spec claimable?(String.t(), String.t()) :: boolean()
  def claimable?(path, backend), do: not File.exists?(path) or marked?(path, backend)

  @doc """
  Remove the agent's own scratch directory, leaving the space directory
  (and every sibling's subdirectory) untouched.
  """
  @spec cleanup(integer(), String.t(), String.t()) :: :ok
  def cleanup(_space_id, _agent_name, "docker") do
    # Nothing to remove: a docker scratch lives in the container and goes when
    # the container does (`Nest.Spaces` → `Nest.Sandbox.Backend.remove_space/3`).
    # Falling through to `remove/4` would `rm_rf` a *host* directory that happens
    # to have the same spelling — the agent's own name under the host's `/tmp`.
    :ok
  end

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
  def remove_stale(_space_id, _agent_name, "docker"), do: :ok

  def remove_stale(space_id, agent_name, backend) do
    # A name that cannot be a path component is the row changeset's refusal to
    # make; there is no directory of that name, and nothing here may raise.
    if single_segment?(agent_name), do: remove(space_id, agent_name, backend, :stale)
    :ok
  end

  @doc """
  The mounts a prompt for `name` is composed through.

  Composing a prompt runs nothing and reads no file through the sandbox —
  `Nest.Agents.Agent.SystemPrompt` reads `AGENTS.md` on the **host** — so what
  the prompt needs from these mounts is the *values* it states: the workspace
  path, the network sentence and the backend's enforcement sentence. They are
  the agent's real mounts for that reason, and the scratch directory is named
  even though it may not exist yet, so a later comparison of a prompt's mounts
  with the agent's is a comparison of like with like.

  `nil` scratch for a name that cannot be a path component: such an agent is
  refused by its own changeset, and nothing composes a prompt for it.

  Naming is not creating. The directory is made by `create/3` when the agent
  starts — that is the only creator on the prompt's path — or by
  `Nest.Sandbox.Mounts.ensure_scratch!/1` when a command is staged. Both mark
  what they make.
  """
  @spec prompt_mounts(String.t() | nil, integer(), String.t(), String.t(), boolean()) ::
          Mounts.t()
  def prompt_mounts(workspace, space_id, name, backend, network_access) do
    # This *names* the directory; it does not make it. The two creators are
    # `create/3` (the start path) and `Nest.Sandbox.Mounts.ensure_scratch!/1`
    # (staging a command, from `Nest.Tools.ShellCmd`), and both mark what they
    # make — see `mark!/2`. Naming mounts must not be what creates a directory,
    # which is why the creation stays in those two. Composing a prompt used to
    # be a third creator by accident, because its `AGENTS.md` read staged a
    # command through `ShellCmd`; that read is now a host read (issue #132), so
    # a scratch path that cannot be made fails where `create/3` runs — in
    # `init/1` — rather than as a raise out of a caller that is merely
    # composing a prompt.
    scratch = if single_segment?(name), do: agent_dir(space_id, name, backend)
    Mounts.new(workspace, scratch, backend, space_id, network_access)
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
  # The two backends whose `/tmp` *is* the scratch root: the host's own under
  # `"none"`, the container's own under `"docker"`. Neither has a per-space root
  # on the host — one because it binds nothing, the other because its root is
  # inside the container — so the agent's directory is the bare name under the
  # `/tmp` spelling, which is what every agent is told it has.
  def space_dir(_space_id, backend) when backend in ["none", "docker"], do: @sandbox_tmp

  # Every other backend gets its own per-space root on the host, under a
  # per-BEAM parent. The clause is open rather than naming `bwrap`, because a
  # backend string this build does not know is refused when a command runs
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

  defp single_segment?(name), do: Nest.Name.valid?(name)
end
