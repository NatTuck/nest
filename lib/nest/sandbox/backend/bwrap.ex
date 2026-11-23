defmodule Nest.Sandbox.Backend.Bwrap do
  @moduledoc """
  The default backend: bubblewrap.

  `Nest.Sandbox.build/2` translates the mode's caps plus the `Mounts` value
  into bwrap's argument list, and this module wraps that in the command line
  that runs the staged script. bwrap enforces the caps itself, so nothing here
  checks anything: the workspace, the scratch bind, the network namespace and
  the project mounts are all bwrap's business (see `Nest.Sandbox`).

  The staged script is reached through the scratch bind, so its host directory
  and the path bash is handed differ: `<space_dir>/.cmds/` on the host,
  `/tmp/.cmds` inside (see `Nest.Sandbox.Paths`). With no scratch bind there is
  no bind to translate through and the two coincide.
  """

  alias Nest.Sandbox
  alias Nest.Sandbox.{Failure, Mounts, NamespaceHolder, Paths}
  alias Nest.Tools.ShellEscape

  @doc """
  `bwrap <args> /bin/bash '<script>'`.

  The script is passed as a *file* to bash rather than as `-c` text, which is
  what removes the escaping layer: the command text never has to survive as one
  quoted argv element.

  When the space has a live namespace holder (#224), the command JOINS the
  holder's user + pid namespace instead of unsharing a fresh one, so `ps` sees
  the space's other commands. The join is wrapped so a host shell opens the
  holder's namespace FDs itself (see `join_command_line/3`). A space with no
  holder that can run falls back to the fresh per-command namespace.

  `cd` is `nil`: `Nest.Sandbox.build/2` already appends `--chdir`, so bwrap
  starts the command in the right directory itself.
  """
  @spec command(Mounts.t(), map() | nil, String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def command(mounts, caps, script) do
    case NamespaceHolder.ensure(Mounts.space_id(mounts)) do
      {:ok, holder} ->
        with {:ok, args} <- build_join_args(mounts, caps) do
          {:ok, %{command: join_command_line(args, script, holder), cd: nil}}
        end

      :error ->
        with {:ok, args} <- build_args(mounts, caps) do
          {:ok, %{command: command_line(args, script), cd: nil}}
        end
    end
  end

  @doc """
  A background job's command line: the same as `command/3`.

  The job's log is an ordinary file under the agent's scratch directory, which
  this backend's environment reaches as a host directory, so
  `Nest.Sandbox.ShellJobs` writes it as the output arrives and there is nothing
  for the command to do.
  """
  @spec job_spec(Mounts.t(), map() | nil, String.t(), String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def job_spec(mounts, caps, script, _log_path), do: command(mounts, caps, script)

  @doc """
  The host staging directory: inside the bound space scratch dir when there is
  one, else under the system tmp dir (see `Nest.Sandbox.Paths.stage_dir/1`).
  """
  @spec stage_dir(Mounts.t()) :: String.t()
  def stage_dir(mounts), do: Paths.stage_dir(Mounts.scratch(mounts))

  @doc """
  The staging directory's path inside the sandbox.
  """
  @spec stage_dir_sandbox(Mounts.t()) :: String.t()
  def stage_dir_sandbox(mounts), do: Paths.stage_dir_sandbox(Mounts.scratch(mounts))

  @doc "The name this backend is logged under."
  @spec display_name(Mounts.t()) :: String.t()
  def display_name(_mounts), do: "bwrap"

  @doc """
  Release the space's persistent namespace holder (#224). Stopping the holder
  tears its user + pid namespace down (`--kill-child`); a space with no holder
  is a no-op.
  """
  @spec remove_space(integer()) :: :ok
  def remove_space(space_id), do: NamespaceHolder.stop_space(space_id)

  @doc """
  Classify stderr with bwrap's own table, which matches bwrap's setup-failure
  markers before the errno strings it reuses (see `Nest.Sandbox.Failure`).
  """
  @spec classify(Mounts.t(), String.t()) :: atom()
  def classify(_mounts, stderr), do: Failure.classify(stderr)

  # `caps: nil` means the legacy default profile, exactly as
  # `ShellCmd.execute/4` documents.
  defp build_args(mounts, caps) do
    Sandbox.build(caps || Sandbox.default_caps(), mounts)
  end

  defp command_line(args, script) do
    Enum.join(["bwrap" | args], " ") <> " /bin/bash " <> ShellEscape.escape(script)
  end

  defp build_join_args(mounts, caps) do
    Sandbox.build_join(caps || Sandbox.default_caps(), mounts)
  end

  # A joined command (#224) runs under a host bash that opens the holder's
  # user + pid namespace FDs and hands them to bwrap. Dynamic FD allocation
  # (`{u}`/`{p}`, >= 10) avoids colliding with the pipes erlexec wires to
  # stdout/stderr. `$0` is the holder's host pid; `"$@"` forwards the bwrap args
  # and the staged script verbatim, so nothing here re-escapes them. The uid/gid
  # are the runtime user's (`id -u`/`id -g`), which is exactly what the holder's
  # identity user namespace maps — so a command runs as that user, never root.
  #
  # erlexec passes this whole string as one argv to `$SHELL -c`, so the single
  # quotes are parsed once by that shell and the body reaches bash intact.
  defp join_command_line(args, script, holder) do
    inner = Enum.join(args, " ") <> " /bin/bash " <> ShellEscape.escape(script)

    # ~S: every byte literal — the body's single and double quotes, `$0`/`$u`/
    # `$@` and `$(id …)` are bash's, not Elixir interpolation.
    wrapper =
      ~S|/bin/bash -c 'exec {u}<"/proc/$0/ns/user"; exec {p}<"/proc/$0/ns/pid"; exec bwrap --userns "$u" --pidns "$p" --uid "$(id -u)" --gid "$(id -g)" "$@"' |

    wrapper <> holder.holder_pid <> " " <> inner
  end
end
