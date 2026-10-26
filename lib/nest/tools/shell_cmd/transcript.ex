defmodule Nest.Tools.ShellCmd.Transcript do
  # Set before the moduledoc because the prose below interpolates it: the value
  # is stated once, here, and every other mention (the moduledoc, `umask/0`, the
  # model-visible `shell-cmd` description) reads it from this attribute.
  @umask "0022"

  @moduledoc """
  The command transcript: the file bash is handed, and the one line that runs
  before every command.

  `Nest.Tools.ShellCmd` stages each command in a file and hands bash that path
  rather than `-c` text. This module owns that staging, so the one thing that
  happens to *every* command before it runs — foreground or background, on
  every backend — lives in one place.

  ## The umask

  A command's file modes are otherwise whatever umask its launcher has: the
  BEAM's for `bwrap` and `none`, the container's for `docker exec`. None of the
  three takes a umask as an option, so the same `mkdir` came out `0777` under a
  launcher with umask `000` and `0775` under `002`, and a world-writable
  directory in the workspace was one inherited value away. The transcript
  therefore starts with `umask #{@umask}`, which is what the command's own file
  creation then sees: directories `0755`, files `0644`.

  Two limits on that, so it is not read as more than it is:

    * it is a *default* — a command that sets its own `umask` later in the
      script overrides it;
    * it covers what the *command* creates. On `"docker"` the wrapper the
      backend builds around it (`mkdir -p` of the scratch dir, a background
      job's `tee`) runs in the container under the container's own umask.

  The cost is one line of preamble, so the script bash reads is one line longer
  than the command text the model sent: `$LINENO`, a re-read of `$0`, and the
  `…/nest-cmd-….sh: line N:` prefixes bash puts on its own diagnostics all count
  from the script, one past the model's numbering.
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

  # The staged name carries a per-VM counter *and* four random bytes: the `none`
  # backend stages into the host's shared `/tmp/.nest-cmds`, so two BEAMs on one
  # host must not be able to pick the same name — one would silently run the
  # other's transcript. (The same scheme as `Nest.DotConfig.Writer.tmp_path/1`.)
  defp script_name do
    "nest-cmd-#{System.unique_integer([:positive])}-" <>
      "#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}.sh"
  end
end
