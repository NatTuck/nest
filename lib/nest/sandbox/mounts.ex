defmodule Nest.Sandbox.Mounts do
  @moduledoc """
  The directories one sandbox invocation binds, as one value.

  `Nest.Sandbox` builds every bind from these two, and each is optional —
  `nil` means "this call binds none of it", not "the agent has none":

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

  They travel together and nothing else does, so they are one value rather
  than two arguments, and the value travels everywhere: a tool, handler or
  agent module holds it and hands it to `Nest.Sandbox`. `Nest.Sandbox` is what
  turns it into binds. What nothing outside the boundary does is need a
  directory in order to name a path an agent uses — an agent names one domain,
  the sandbox domain, and `resolve/2` is the only thing that turns a relative
  tool path into an absolute one.

  The directories are still *read* outside the boundary, by the modules that
  need a real directory for real file work rather than to name an agent's path:
  `Nest.Tools.ShellCmd` stages command transcripts into the scratch dir and
  passes the resulting sandbox spelling to bash; `Nest.Tools.FileTools`,
  `Nest.Tools.InspectFile` and `Nest.Agents.Agent.SystemPrompt` resolve a
  relative tool path with `resolve/2`; `Nest.Agents.Agent.BatchSizer.Overflow`
  writes offloaded results into the scratch dir; `Nest.ProjectConfig` reads
  `<workspace>/.nest` and backs a `mode = "tmp"` mount under the scratch dir.
  Three of those write into the scratch dir *without* going through bwrap —
  `ShellCmd.stage_script/2` (`Paths.stage_dir/1` plus `Paths.stage_dir_sandbox/1`),
  `Overflow.write/4` and `Nest.Sandbox.ShellJobs`'s job logs — and each of the
  three hands the agent the `/tmp/<agent-name>/...` spelling of what it wrote,
  never the directory it wrote to.
  """

  alias Nest.FSPath

  @enforce_keys [:workspace, :scratch]
  defstruct [:workspace, :scratch]

  @typedoc """
  `workspace` is the workspace this call binds (or `nil`); `scratch` is the
  agent's scratch directory this call binds (or `nil`). Either may be `nil`:
  see the moduledoc.
  """
  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          scratch: String.t() | nil
        }

  @doc """
  The mounts for a call that binds `workspace` and `scratch`. Either may be
  `nil` for "this call binds none of it" (see the moduledoc).
  """
  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(workspace, scratch), do: %__MODULE__{workspace: workspace, scratch: scratch}

  @doc """
  The mounts for an agent's state: the workspace it works in and the scratch
  directory it owns. This is the one place the two directories are read out of
  agent state, so every tool, handler and agent module holds the value rather
  than a pair of directories.

  The match is hard on both keys because every call site passes an
  `%Nest.Agents.Agent{}`, whose struct always carries them; an agent-shaped map
  without them is a bug, not a case to absorb.
  """
  @spec from_agent(%{
          optional(atom()) => term(),
          workspace_path: String.t() | nil,
          tmp_path: String.t() | nil
        }) :: t()
  def from_agent(%{workspace_path: workspace_path, tmp_path: tmp_path}) do
    new(workspace_path, tmp_path)
  end

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
