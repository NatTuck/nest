defmodule Nest.Tools.ShellCmd.Transcript do
  # Set before the moduledoc because the prose below interpolates it: the value
  # is stated once, here, and every other mention (the moduledoc, `umask/0`, the
  # model-visible `shell-cmd` description) reads it from this attribute.
  @umask "0022"

  @moduledoc """
  The command transcript: the file bash is handed, and the one line that runs
  before every command.

  `Nest.Tools.ShellCmd` never passes a command to bash as `-c` text. It stages
  the command in a file and hands bash that path, which is what removes the
  escaping layer (see that module's "The command transcript"). This module owns
  the staging, so the one thing that happens to *every* command before it runs
  — foreground or background, on every backend — lives in one place.

  ## The umask

  A command's file modes are otherwise whatever umask the BEAM inherited from
  whatever started it, which is neither a property of the sandbox nor visible
  to the agent. That made a directory an agent creates come out `0777` under a
  launcher with umask `000` and `0775` under `002`: a world-writable directory
  in the workspace was one inherited value away. So the transcript starts with
  `umask #{@umask}` — directories `0755`, files `0644`, on every backend.

  It is a *default*, not a lock: a command that sets its own `umask` later in
  the script overrides it. The cost is one line of preamble, so a command that
  reads `$LINENO` (or re-reads `$0`) sees the script one line longer than the
  command text the model sent.

  No backend can do this instead: bwrap, `docker exec` and a bare fork all
  inherit the BEAM's umask, and none of the three takes one as an option.
  """

  alias Nest.Sandbox.{Backend, Mounts}

  @doc """
  The umask every staged command starts with: `#{@umask}`.

  Public because the model-visible `shell-cmd` description interpolates it, so
  the prose cannot drift from the preamble — the same reason
  `Nest.Tools.ShellCmd.default_timeout_ms/0` is public.
  """
  @spec umask() :: String.t()
  def umask, do: @umask

  @doc """
  Stage `command` for bash to read on `mounts`' backend.

  Returns `{host_path, sandbox_path}`: where the file actually is, and the
  spelling bash is handed. The two differ whenever the staging directory is
  reached through a bind, and the caller needs both — the host path to remove
  it afterwards, the sandbox spelling to hand the backend.
  """
  @spec stage(String.t(), Mounts.t()) :: {String.t(), String.t()}
  def stage(command, mounts) do
    dir = Backend.stage_dir(mounts)
    File.mkdir_p!(dir)
    path = Path.join(dir, script_name())
    File.write!(path, "umask #{@umask}\n" <> command)
    {path, Path.join(Backend.stage_dir_sandbox(mounts), Path.basename(path))}
  end

  defp script_name do
    "nest-cmd-#{System.unique_integer([:positive])}.sh"
  end
end
