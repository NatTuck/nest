defmodule Nest.Sandbox.Mounts do
  @moduledoc """
  How one sandbox invocation is realized: which backend runs it, and the
  directories that backend binds.

  `backend` names the implementation — `"bwrap"`, `"docker"` or `"none"` (see
  `Nest.Sandbox.Backend`) — and is a space property, resolved once from the
  space row when the agent starts. The other two are the directories, and each
  is optional: `nil` means "this call binds none of it", not "the agent has
  none":

    * `space_id` — the space this call belongs to. A backend that keeps an
      environment outside the BEAM names that environment after the space
      (docker's container is `nest-space-<space_id>-…`), and the space id cannot
      be recovered from either directory: the scratch path embeds the BEAM's pid
      and reading an id back out of it would be a reverse mapping.
    * `space_name` — the space's *name*, for the one thing a prompt needs it
      for: a `"none"` space has no enforced scratch directory, so its prompt
      suggests `/tmp/nest/<space-name>/` (`Nest.Agents.Agent.SystemPrompt`). It
      is a value carried here rather than a schema read, because nothing under
      `lib/nest/sandbox/` reads the spaces schema: the caller that already has
      the row puts it on this struct
      (`Nest.Persistence.put_space_properties/1` does, and only for a `"none"`
      space). `nil` everywhere else — a sandboxed space's scratch is real and
      needs no suggestion, and its prompt must stay byte-identical.
    * `network_access` — whether this call may reach the network. It is the
      *space's* value (`spaces.network_access`), resolved once at agent start
      like the backend, and injected into the resolved caps as `"net"`
      (`Nest.Sandbox.with_network_access/2`) so no caps resolution has to read
      the DB. `false` when the value names no space, which is what
      `Nest.Sandbox.default_caps/0` has.
    * `workspace` — bound at its own path when the mode's caps grant
      `":workspace"`, and the base a relative tool path resolves against.
    * `scratch` — the agent's own scratch directory, which the agent names as
      `/tmp/<agent-name>`. Its *parent* is bound at `/tmp` under a backend whose
      scratch is a host directory (see `scratch_bind_source/1`); under `"docker"`
      it is a path *inside the container*, whose `/tmp` is the scratch and which
      nothing on the host may create or write (`host_scratch?/1`).

  A caller passes what its call actually needs, and `nil` is a legitimate
  half — the value describes one call's binds, not the agent's.

  Composing the system prompt is not one of those halves either, and it no
  longer runs anything: `AGENTS.md` and `.nest` are read on the **host**
  (`Nest.ConfigFile.read/1` is the one reader), so a prompt's
  mounts are only *stated* — the workspace path, the network sentence and the
  backend's enforcement sentence all come from this value. They are still the
  agent's real mounts, scratch included
  (`Nest.Agents.Agent.TmpSpace.prompt_mounts/6` is the one place that builds
  them), so what the prompt says about its environment is what its tools will
  do.

  ## The value is the agent's

  An agent holds this value for its whole life (`Nest.Agents.Agent.mounts`),
  built once at init from the attrs the start path resolved — the workspace,
  the scratch directory `Nest.Agents.Agent.TmpSpace` created, and the space's
  backend. `from_agent/1` is the one accessor, so no tool, handler or agent
  module holds a pair of directories or a backend string of its own, and
  `Nest.Sandbox` is what turns the value into binds.

  What nothing outside the boundary does is need a directory in order to name
  a path an agent uses — an agent names one domain, the sandbox domain, and
  `resolve/2` is the only thing that turns a relative tool path into an
  absolute one.

  The directories are still *read* outside the boundary, and not only for file
  work:

    * `resolve/2`, to turn a relative tool path into an absolute one:
      `Nest.Tools.FileTools`, `Nest.Tools.InspectFile`,
      `Nest.Agents.Agent.IntrospectionHandler` and
      `Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess`.
    * The workspace, to name it to the agent or to an operator log:
      `Nest.Agents.Agent.SystemPrompt` (the working-directory, project-config
      and `AGENTS.md` sections), `Nest.ProjectConfig` (which reads
      `<workspace>/.nest`), and `Nest.Tools`, `Nest.Tools.FileTools`,
      `Nest.Tools.InspectFile` and `Nest.Tools.ShellCmd`, which print it.
    * The scratch directory: `Nest.Tools` prints it; `Nest.Tools.ShellCmd`
      creates it (`ensure_scratch!/1`), stages the command transcript in it
      (`Nest.Sandbox.Paths.stage_dir/1`) and prints it in its two failure
      diagnostics; `Nest.Agents.Agent.BatchSizer.Overflow` writes an offloaded
      result into it; `Nest.ProjectConfig` creates `<scratch>/project/<slug>`
      as the bind source for a `mode = "tmp"` mount (`ensure_dirs/1`).

  Of the modules that write into the scratch directory without going through
  the sandbox, each reports a *sandbox* path back rather than the directory it
  wrote to — except the last, which only creates a directory:
  `ShellCmd.stage_script/2` stages in the staging dir (`/tmp/.cmds/<script>`
  with a scratch bind, `/tmp/.nest-cmds/<script>` without), a sibling of the
  agent's own directory rather than a child of it — deliberately, so a glob
  over the agent's scratch tree never sees it — and hands that path to bash,
  not to the agent; `Overflow.write/4` returns `/tmp/<agent-name>/<name>`;
  `Nest.Sandbox.ShellJobs` reports `/tmp/<agent-name>/shell-jobs/<job>.log`;
  `Nest.ProjectConfig.ensure_dirs/1` `mkdir_p`s `<scratch>/project/<slug>` and
  reports nothing.
  """

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.FSPath
  alias Nest.Sandbox.Backend
  alias Nest.Sandbox.Paths

  @enforce_keys [:workspace, :scratch]
  # The backend default comes from `Nest.Sandbox.Backend`, the list's one home —
  # a second literal here would be a second source of truth. Only the default is
  # taken; nothing here branches on the value. Network access defaults to
  # `false`, which is what a value naming no space means (see the moduledoc), and
  # `space_name` to `nil`, which is what every backend but `"none"` wants.
  defstruct [
    :workspace,
    :scratch,
    :space_id,
    :space_name,
    network_access: false,
    backend: Backend.default()
  ]

  @typedoc """
  `backend` is the implementation that runs the invocation (a string from
  `Nest.Sandbox.Backend.backends/0`); `space_id` is the space whose environment
  it is (`nil` for a call that belongs to no space); `workspace` is the
  workspace this call binds (or `nil`); `scratch` is the agent's scratch
  directory this call binds (or `nil`). Either directory may be `nil`: see the
  moduledoc.
  """
  @type t :: %__MODULE__{
          backend: String.t(),
          space_id: integer() | nil,
          space_name: String.t() | nil,
          network_access: boolean(),
          workspace: String.t() | nil,
          scratch: String.t() | nil
        }

  @doc """
  The mounts for a call that binds `workspace` and `scratch` on the default
  backend. Either directory may be `nil` for "this call binds none of it" (see
  the moduledoc).

  The backend defaults to `Nest.Sandbox.Backend.default/0`
  because most callers genuinely have no space to ask: a test fixture, a
  doc-example, and the `Nest.Tools` tool-description builders all want the
  default backend. A caller that *does* know the space's backend must pass it
  with `new/3` — a system-prompt composition or a tool closure that runs a
  command is executing through the backend it names, so defaulting there would
  run a `"none"` space's work under bwrap.
  """
  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(workspace, scratch), do: %__MODULE__{workspace: workspace, scratch: scratch}

  @doc """
  The mounts for a call that binds `workspace` and `scratch` on `backend`, in no
  space.
  """
  @spec new(String.t() | nil, String.t() | nil, String.t()) :: t()
  def new(workspace, scratch, backend),
    do: %__MODULE__{backend: backend, workspace: workspace, scratch: scratch}

  @doc """
  The mounts for a call that binds `workspace` and `scratch` on `backend` in
  `space_id`.

  The space is what a backend that keeps an environment outside the BEAM names
  that environment after — the docker backend's container is
  `nest-space-<space_id>-<BEAM pid>-<layout hash>` — and the space id cannot be
  recovered from either directory: the scratch path embeds the BEAM's pid, and
  reading an id back out of a path would be a reverse mapping this codebase
  deliberately does not have. A call that belongs to no space passes `nil` and
  gets an error from a backend that needs one, rather than a container shared by
  accident.
  """
  @spec new(String.t() | nil, String.t() | nil, String.t(), integer() | nil) :: t()
  def new(workspace, scratch, backend, space_id) do
    %__MODULE__{backend: backend, space_id: space_id, workspace: workspace, scratch: scratch}
  end

  @doc """
  The mounts for a call in a space, with everything that space decides: the
  backend it runs, its network access, and the two directories this call binds.
  """
  @spec new(String.t() | nil, String.t() | nil, String.t(), integer() | nil, boolean()) :: t()
  def new(workspace, scratch, backend, space_id, network_access) do
    %__MODULE__{
      backend: backend,
      space_id: space_id,
      network_access: network_access,
      workspace: workspace,
      scratch: scratch
    }
  end

  @doc """
  The mounts for a call in a space, with everything that space decides — the
  backend it runs, its network access, the two directories this call binds — and
  the space's name, which only a `"none"` space's prompt reads (`space_name/1`).
  """
  @spec new(
          String.t() | nil,
          String.t() | nil,
          String.t(),
          integer() | nil,
          boolean(),
          String.t() | nil
        ) ::
          t()
  def new(workspace, scratch, backend, space_id, network_access, space_name) do
    %__MODULE__{
      backend: backend,
      space_id: space_id,
      space_name: space_name,
      network_access: network_access,
      workspace: workspace,
      scratch: scratch
    }
  end

  @doc """
  The mounts for an agent's state: the backend its space runs and the two
  directories it owns. This is the one place the value is read out of agent
  state, so every tool, handler and agent module holds the value rather than a
  backend and a pair of directories.

  The match is hard because every call site passes an `%Nest.Agents.Agent{}`,
  which always carries `:mounts`; an agent-shaped map without it is a bug, not
  a case to absorb.
  """
  @spec from_agent(%{required(:mounts) => t()}) :: t()
  def from_agent(%{mounts: %__MODULE__{} = mounts}), do: mounts

  @doc """
  The workspace directory, or `nil`.
  """
  @spec workspace(t()) :: String.t() | nil
  def workspace(%__MODULE__{workspace: workspace}), do: workspace

  @doc """
  The agent's scratch directory, or `nil`.
  """
  @spec scratch(t()) :: String.t() | nil
  def scratch(%__MODULE__{scratch: scratch}), do: scratch

  @doc """
  The backend that runs this call: `"bwrap"`, `"docker"` or `"none"`.
  """
  @spec backend(t()) :: String.t()
  def backend(%__MODULE__{backend: backend}), do: backend

  @doc """
  The space whose environment this call runs in, or `nil`.
  """
  @spec space_id(t()) :: integer() | nil
  def space_id(%__MODULE__{space_id: space_id}), do: space_id

  @doc """
  The space's name, or `nil`.

  One reader: a `"none"` space's system prompt, which suggests
  `/tmp/nest/<space-name>/` because such a space has no enforced scratch
  directory. `nil` for a call that names no space and for every other backend —
  see the moduledoc for why the name travels as a value.
  """
  @spec space_name(t()) :: String.t() | nil
  def space_name(%__MODULE__{space_name: space_name}), do: space_name

  @doc """
  The directory this call binds at `/tmp`, or `nil` when it binds none.

  That is the scratch *root* — the parent of the agent's own scratch dir —
  under a backend whose scratch is a host directory. `"docker"` answers the
  container's own `/tmp`: there is nothing there to bind, but the bind still
  has a job, because `Nest.Sandbox.Binds` renders it as a self-bind whose *mode*
  is what makes the scratch writable at all. A `"none"` space binds nothing
  (it has no sandbox), so its answer is unused; it is `/tmp` for the same
  reason the spelling and the directory coincide there.
  """
  @spec scratch_bind_source(t()) :: String.t() | nil
  def scratch_bind_source(%__MODULE__{scratch: nil}), do: nil

  def scratch_bind_source(%__MODULE__{backend: backend}) when backend in ["docker", "none"],
    do: Paths.sandbox_root()

  def scratch_bind_source(%__MODULE__{scratch: scratch}), do: Paths.scratch_root(scratch)

  @doc """
  Whether this call's scratch directory is a directory on the host.

  It is under every backend whose environment *is* the host: a bwrap space's
  scratch is a real directory, and a `"none"` space's scratch is the host's own
  `/tmp/<agent-name>`. Under `"docker"` it is not — `scratch/1` names a path
  inside the container, and only the container can write it — which is what the
  few callers that write a scratch file directly have to ask before doing so.
  """
  @spec host_scratch?(t()) :: boolean()
  def host_scratch?(%__MODULE__{backend: "docker"}), do: false
  def host_scratch?(%__MODULE__{}), do: true

  @doc """
  Whether this call may reach the network: the space's value, or `false` for a
  call that names no space.
  """
  @spec network_access(t()) :: boolean()
  def network_access(%__MODULE__{network_access: network_access}), do: network_access

  @doc """
  Create the agent's scratch directory when there is one, so a command can be
  staged in it. A no-op when there is no scratch directory.

  This is the *second* creator of a scratch directory (the first is
  `Nest.Agents.Agent.TmpSpace.create/3`, on the start path), and it marks what it
  makes: a `"none"` scratch is the host's own `/tmp/<name>`, and one made without
  the marker would be a directory no later `cleanup/3` could ever remove. An
  existing directory is never touched — in particular, something at that path
  that is not Nest's is left unmarked, which is what keeps the marker meaning
  "Nest made this" (see `Nest.Agents.Agent.TmpSpace`).
  """
  @spec ensure_scratch!(t()) :: :ok
  def ensure_scratch!(%__MODULE__{scratch: nil}), do: :ok

  # A docker scratch names a path inside the container, which nothing on the
  # host may make: creating it here would create a *host* directory at a path
  # the agent only ever means inside the container, and the container could not
  # see it anyway. The container makes it, in the command that runs (see
  # `Nest.Sandbox.Backend.Docker`).
  def ensure_scratch!(%__MODULE__{backend: "docker"}), do: :ok

  def ensure_scratch!(%__MODULE__{scratch: dir} = mounts) do
    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      TmpSpace.mark!(dir, backend(mounts))
    end

    :ok
  end

  @doc """
  Resolve a tool path against the workspace root: an absolute path is used
  as-is, a relative path joins the workspace.

  Returns `{:error, "No workspace configured for this agent"}` for a relative
  path when there is no workspace to resolve it against.
  """
  @spec resolve(String.t(), t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, %__MODULE__{workspace: workspace}), do: FSPath.resolve(path, workspace)
end
