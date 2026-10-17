defmodule Nest.Sandbox.Backend.None do
  @moduledoc """
  The unsandboxed backend: the bare command, on the host.

  A space created with `sandbox_backend: "none"` runs its agents' commands
  directly, with no isolation of any kind. The mode's caps are therefore
  **not enforced** — there is no namespace to unshare, no bind to make
  read-only, and no filesystem view to restrict. That is the point of the
  backend (a space that must reach the real machine, including the devices and
  the host's own `/tmp`), and it is stated plainly where the backend is chosen
  (`Nest.Spaces.Space`'s moduledoc, and the New Space form's help text) rather
  than papered over here.

  What does *not* change is the paths the agent names: `Nest.Agents.Agent.TmpSpace`
  roots a `"none"` space's scratch at the real `/tmp`, so `/tmp/<agent-name>`
  is literally true, and the workspace is its own path. The staging directory
  is `Nest.Sandbox.Paths.stage_dir/1`'s no-scratch-bind form
  (`/tmp/.nest-cmds`) — `Paths.scratch_root/1` refuses `/tmp` as a bind source
  (binding it would be a sandbox escape), and with no bind there is nothing to
  translate, so the host path and the handed path are the same string.
  """

  alias Nest.Sandbox.{Failure, Mounts, Paths}
  alias Nest.Tools.ShellEscape

  @doc """
  `/bin/bash '<script>'`, started in the workspace.

  `cd` carries the workspace because there is no bwrap to `--chdir`: this is
  where `ShellCmd` passes erlexec's `{:cd, dir}` so a `"none"` command starts
  in the same directory a bwrap one would.
  """
  @spec command(Mounts.t(), map() | nil, String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def command(mounts, _caps, script) do
    {:ok, %{command: "/bin/bash " <> ShellEscape.escape(script), cd: Mounts.workspace(mounts)}}
  end

  @doc """
  A background job's command line: the same as `command/3`, because this
  environment *is* the host — the job's log is a file the manager writes
  directly.
  """
  @spec job_spec(Mounts.t(), map() | nil, String.t(), String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def job_spec(mounts, caps, script, _log_path), do: command(mounts, caps, script)

  @doc """
  The host staging directory: `Nest.Sandbox.Paths.stage_dir/1`'s
  no-scratch-bind form, because a `"none"` space has no scratch bind at all
  (its scratch *is* the host's `/tmp`).
  """
  @spec stage_dir(Mounts.t()) :: String.t()
  def stage_dir(_mounts), do: Paths.stage_dir(nil)

  @doc """
  The staging directory's spelling inside this environment: the same path,
  since the environment is the host.
  """
  @spec stage_dir_sandbox(Mounts.t()) :: String.t()
  def stage_dir_sandbox(_mounts), do: Paths.stage_dir(nil)

  @doc "The name this backend is logged under."
  @spec display_name(Mounts.t()) :: String.t()
  def display_name(_mounts), do: "the bare command"

  @doc """
  Classify stderr with the errno table only.

  A bare command has no setup phase, so bwrap's setup-failure markers are not
  in play — and matching them here would let a command that merely prints the
  word `bwrap:` be reported to the agent as a broken sandbox. A failure this
  backend cannot classify stays `:read_failed`, the same fallback bwrap uses.
  """
  @spec classify(Mounts.t(), String.t()) :: atom()
  def classify(_mounts, stderr), do: Failure.classify_errno(stderr)
end
