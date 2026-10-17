defmodule Nest.Sandbox.Paths do
  @sandbox_root "/tmp"

  @moduledoc """
  The single definition of the space scratch bind and the sandbox-domain
  spelling of a scratch path.

  The space scratch dir is bound at `#{@sandbox_root}` inside the sandbox
  (by the backends that bind anything), so an agent's own scratch dir (the
  space dir plus `<agent-name>`) is `#{@sandbox_root}/<agent-name>` inside.
  `scratch_root/1` is the one bind source (`Nest.Sandbox.Binds` uses it) and
  `sandbox_tmp_path/1` is the one inverse mapping, so the mount
  and the spelling cannot drift.

  A `"none"` space binds nothing: its scratch root *is* the host's
  `#{@sandbox_root}`, so the spelling and the directory coincide there (see
  `Nest.Sandbox.Backend.None`). A `"docker"` space's scratch is the
  *container's* own `#{@sandbox_root}`, which is likewise nothing to bind —
  but its staged command transcripts are the one thing that has to live on the
  host and be reached from inside, so they get a directory of their own
  (`docker_stage_dir/1`).

  There is deliberately **no** path translation here: the sandbox's
  filesystem view is the active backend's view, and every `read`/`stat`/`glob`
  executes inside it (see `Nest.Sandbox`). `TmpSpace` produces the agent's
  scratch directory; `Paths` derives the mount and the spelling from it.
  `Paths` must not depend on `TmpSpace`.

  ## A scratch directory is a bind source, not an address

  The agent names exactly one domain of paths, and it is the sandbox domain:
  `#{@sandbox_root}/<agent>/...` for scratch, and the workspace's own path
  for the workspace (which the sandbox binds at that same path). A scratch
  directory is only ever an *input* to that view — what `Nest.Sandbox` binds.
  Every function here that takes one is called from `Nest.Sandbox` or from
  `Nest.Tools.ShellCmd` (which stages command transcripts through
  `stage_dir/1`), and its result is either a bind source or the
  `#{@sandbox_root}/<agent>/...` spelling the agent uses. No value from this
  module belongs in a tool description, a tool result, or anything else the
  agent sees.
  """

  alias Nest.FSPath
  alias Nest.Sandbox.Installation

  # The staging directory name, relative to the space scratch root (when a
  # scratch bind exists) or to `System.tmp_dir!()`/`@sandbox_root` (when it
  # does not). See `stage_dir/1`.
  @stage_subdir ".cmds"
  @no_scratch_stage_subdir ".nest-cmds"

  @doc """
  The mount point the space scratch dir is bound at inside the sandbox.
  """
  @spec sandbox_root() :: String.t()
  def sandbox_root, do: @sandbox_root

  @doc """
  The directory bound at `#{@sandbox_root}` inside the sandbox: the parent of
  the agent's own scratch dir. Refuses `/` or `#{@sandbox_root}` (binding the
  whole `#{@sandbox_root}` would be a sandbox escape).
  """
  @spec scratch_root(String.t()) :: String.t()
  def scratch_root(tmp_path) do
    # The bind source. What the agent sees at /tmp is /tmp/<agent>/... — see
    # sandbox_tmp_path/1 — and this value is never handed to the agent.
    root = Path.dirname(tmp_path)

    if root in ["/", @sandbox_root] do
      raise ArgumentError, "refusing to use #{inspect(root)} as a scratch bind root"
    end

    FSPath.canonical(root)
  end

  @doc """
  The path an agent's own scratch dir (`tmp_path`) appears at inside the
  sandbox: `#{@sandbox_root}/<agent-name>` (the space dir is bound at
  `#{@sandbox_root}`).

  This is the only scratch spelling an agent is ever told about or hands
  back; the scratch directory it is derived from is the caller's, and is never
  given to the agent.
  """
  @spec sandbox_tmp_path(String.t()) :: String.t()
  def sandbox_tmp_path(tmp_path), do: Path.join(@sandbox_root, Path.basename(tmp_path))

  @doc """
  The SANDBOX spelling of an agent's own scratch directory, derived from the
  agent's *name* alone: `#{@sandbox_root}/<agent-name>`.

  `sandbox_tmp_path/1` needs the agent's scratch directory; this needs only
  the name, so callers that have just the name (the prompt composer, the
  clone notice) can state the spelling without one. The name is the scratch
  segment (`Nest.Agents.PersistedAgent` enforces that), so the two agree.

  SANDBOX PATH — the contrast with `scratch_root/1`, which returns the
  directory the sandbox binds at `#{@sandbox_root}`.
  """
  @spec scratch_dir(String.t()) :: String.t()
  def scratch_dir(name), do: Path.join(@sandbox_root, name)

  @doc """
  The directory `Nest.Tools.ShellCmd` stages command transcripts in.

  With a scratch bind, it lives *inside* the bound space dir
  (`<space_dir>/#{@stage_subdir}`) but in its own subdirectory, so a glob over
  the scratch tree can skip the staging dir rather than hide real files by
  name. Without a scratch bind, it lives under `System.tmp_dir!()`
  (`#{@no_scratch_stage_subdir}`), visible inside the sandbox at the same path
  through the root read-only bind.

  A bind source — internal staging only; never advertised to the agent.
  """
  @spec stage_dir(String.t() | nil) :: String.t()
  def stage_dir(nil), do: Path.join(System.tmp_dir!(), @no_scratch_stage_subdir)
  def stage_dir(tmp_path), do: Path.join(scratch_root(tmp_path), @stage_subdir)

  @doc """
  The spelling of `stage_dir/1` inside the sandbox: `#{@sandbox_root}/#{@stage_subdir}`
  when a scratch bind exists, otherwise the path unchanged (no scratch bind
  means the system tmp dir is the sandbox's `#{@sandbox_root}`).
  """
  @spec stage_dir_sandbox(String.t() | nil) :: String.t()
  def stage_dir_sandbox(nil), do: stage_dir(nil)
  def stage_dir_sandbox(_tmp_path), do: Path.join(@sandbox_root, @stage_subdir)

  @doc """
  The host directory a `"docker"` space stages its command transcripts in.

  A docker space has no host scratch directory — its scratch is the container's
  own `#{@sandbox_root}` — but the transcript is written by the BEAM and read
  by the container, so it needs a directory on the host that the container can
  be given. This is that directory, bound at
  `#{Path.join(@sandbox_root, @stage_subdir)}` read-only (see
  `Nest.Sandbox.Backend.Docker`).

  It is keyed on the space and the *installation*
  (`Nest.Sandbox.Installation`) and deliberately **not** on the BEAM's pid: the
  container outlives a restart, so the directory it binds has to as well. Two
  installations that share a space id get different directories, exactly as
  they get different containers.
  """
  @spec docker_stage_dir(integer()) :: String.t()
  def docker_stage_dir(space_id) do
    Path.join([System.tmp_dir!(), docker_space_dir(space_id), @stage_subdir])
  end

  @doc """
  The spelling of `docker_stage_dir/1` inside the container.

  Always `#{Path.join(@sandbox_root, @stage_subdir)}`: the container's own
  `#{@sandbox_root}` is its scratch, so the staging directory is the one thing
  bound into it rather than derived from it.
  """
  @spec docker_stage_dir_sandbox() :: String.t()
  def docker_stage_dir_sandbox, do: Path.join(@sandbox_root, @stage_subdir)

  defp docker_space_dir(space_id) do
    "nest-docker-#{Installation.segment()}-space-#{space_id}"
  end
end
