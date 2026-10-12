defmodule Nest.Sandbox.Mounts do
  @moduledoc """
  The two directories a sandbox binds, as one value.

  `Nest.Sandbox` builds every bind from exactly these two directories:

    * `workspace` — bound at its own path when the mode's caps grant
      `":workspace"`, and the base a relative tool path resolves against.
      `nil` means "no workspace".
    * `scratch` — the agent's own scratch directory. Its *parent* is bound at
      `/tmp`, so the agent's scratch area appears inside the sandbox at
      `/tmp/<agent-name>`. `nil` means "no scratch bind".

  They travel together and nothing else does, so they are one value rather
  than two arguments: every tool, handler and agent module holds this value
  and hands it to `Nest.Sandbox`, and only the sandbox boundary reads the
  directories back out. An agent addresses paths in one domain — the sandbox
  domain — so nothing outside the boundary needs a directory to name a path
  an agent uses; `resolve/2` is the only thing that turns a relative tool path
  into an absolute one.

  `scratch/1` is read by the two modules that manage the agent's scratch area
  on its behalf *without* going through bwrap:
  `Nest.Agents.Agent.BatchSizer.Overflow` writes offloaded results there, and
  `Nest.Sandbox.ShellJobs` writes background job logs there. Both hand the
  agent the sandbox spelling (`/tmp/<agent-name>/...`) of what they wrote.
  """

  alias Nest.FSPath

  @enforce_keys [:workspace, :scratch]
  defstruct [:workspace, :scratch]

  @typedoc """
  `workspace` is the workspace directory (or `nil` for "no workspace");
  `scratch` is the agent's scratch directory (or `nil` for "no scratch bind").
  """
  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          scratch: String.t() | nil
        }

  @doc """
  The mounts for an agent whose workspace is `workspace` and whose scratch
  directory is `scratch`.
  """
  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(workspace, scratch), do: %__MODULE__{workspace: workspace, scratch: scratch}

  @doc """
  The mounts for an agent's state: the workspace it works in and the scratch
  directory it owns. This is the one place the two directories are read out of
  agent state, so every tool, handler and agent module holds the value rather
  than a pair of directories.
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
