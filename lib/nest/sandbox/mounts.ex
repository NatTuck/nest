defmodule Nest.Sandbox.Mounts do
  @moduledoc """
  How one sandbox invocation is realized: which backend runs it, and the
  directories that backend binds.

  `backend` names the implementation — `"bwrap"`, `"docker"` or `"none"` (see
  `Nest.Sandbox.Backend`) — and is a space property, resolved once from the
  space row when the agent starts. The other two are the directories, and each
  is optional: `nil` means "this call binds none of it", not "the agent has
  none":

    * `workspace` — bound at its own path when the mode's caps grant
      `":workspace"`, and the base a relative tool path resolves against.
    * `scratch` — the agent's own scratch directory. Its *parent* is bound at
      `/tmp`, so the agent's scratch area appears inside the sandbox at
      `/tmp/<agent-name>`.

  A caller passes what its call actually needs, and `nil` is a legitimate
  half — the value describes one call's binds, not the agent's. Composing the
  system prompt reads `AGENTS.md` through the sandbox with
  `new(workspace, nil)`: the file is an absolute path in the workspace, so a
  scratch bind could not change those bytes.

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
      `Nest.Agents.Agent.SystemPrompt`, `Nest.Agents.Agent.IntrospectionHandler`
      and `Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess`.
    * The workspace, to name it to the agent or to an operator log:
      `Nest.Agents.Agent.SystemPrompt` (the working-directory and
      project-config sections), `Nest.ProjectConfig` (which reads
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

  alias Nest.FSPath
  alias Nest.Spaces.Space

  @enforce_keys [:workspace, :scratch]
  # The backend's default comes from `Nest.Spaces.Space` because that is the one
  # home of the list (`sandbox_backends/0` / `default_sandbox_backend/0`), not
  # because a sandbox module has any business knowing about the spaces schema:
  # a second literal here would be a second source of truth. Only the default is
  # taken; nothing here branches on the value.
  defstruct [:workspace, :scratch, backend: Space.default_sandbox_backend()]

  @typedoc """
  `backend` is the implementation that runs the invocation (a string from
  `Nest.Spaces.Space.sandbox_backends/0`); `workspace` is the workspace this
  call binds (or `nil`); `scratch` is the agent's scratch directory this call
  binds (or `nil`). Either directory may be `nil`: see the moduledoc.
  """
  @type t :: %__MODULE__{
          backend: String.t(),
          workspace: String.t() | nil,
          scratch: String.t() | nil
        }

  @doc """
  The mounts for a call that binds `workspace` and `scratch` on the default
  backend. Either directory may be `nil` for "this call binds none of it" (see
  the moduledoc).

  The backend defaults to `Nest.Spaces.Space.default_sandbox_backend/0`
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
  The mounts for a call that binds `workspace` and `scratch` on `backend`.
  """
  @spec new(String.t() | nil, String.t() | nil, String.t()) :: t()
  def new(workspace, scratch, backend),
    do: %__MODULE__{backend: backend, workspace: workspace, scratch: scratch}

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
  Create the agent's scratch directory when there is one, so a command can be
  staged in it. A no-op when there is no scratch directory.
  """
  @spec ensure_scratch!(t()) :: :ok
  def ensure_scratch!(%__MODULE__{scratch: nil}), do: :ok

  def ensure_scratch!(%__MODULE__{scratch: dir}) do
    File.mkdir_p!(dir)
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
