defmodule Nest.Sandbox.Backend do
  @moduledoc """
  The one dispatch point for *how* a sandbox invocation is realized.

  Everything an agent runs — a `shell-cmd`, a `read`, a `stat`, a `glob`, a
  write, a background job — funnels through `Nest.Tools.ShellCmd`, and
  `ShellCmd` asks this module which backend to use. That is the whole seam: no
  tool, handler or executor names a backend, so adding one changes this module
  and adds a `Nest.Sandbox.Backend.*` implementation, and nothing else.

  The backend travels on the `Nest.Sandbox.Mounts` value
  (`Nest.Sandbox.Mounts.backend/1`), which is built once per agent from its
  space's row and carried everywhere a command runs — so no exec path needs a
  DB read.

  ## The contract an implementation fulfils

  A backend turns a `Nest.Sandbox.Mounts` value plus the mode's caps into a
  command line, and answers four questions about the environment it builds:

    * `command/3` — the command line that runs the staged script, plus the
      working directory to start it in (`nil` when the backend's own arguments
      already set one).
    * `stage_dir/1` — the host directory the command's transcript is staged
      into, and `stage_dir_sandbox/1` — the spelling the script is handed at
      *inside* that environment. The two differ whenever the staging directory
      is reached through a bind, and coincide when the environment is the host.
    * `display_name/1` — how the backend is named in an operator log line.
    * `classify/2` — the error atom for a failed command, from its stderr. The
      atoms are the shared vocabulary the file tools render
      (`Nest.Sandbox.Failure`).

  ## The three backends

  * `"bwrap"` (the default) — `Nest.Sandbox.Backend.Bwrap`. Commands run under
    bubblewrap, which enforces the mode's caps: the workspace and scratch
    binds, the network namespace, the project mounts.
  * `"docker"` — `Nest.Sandbox.Backend.Docker`. Commands run inside a container
    shared by the space, which sees the workspace and the explicit `.nest`
    mounts and nothing else of the host.
  * `"none"` — `Nest.Sandbox.Backend.None`. Commands run on the host with no
    sandbox at all. **Caps cannot be enforced** for a space on this backend;
    it is the escape hatch for a space that must reach the real machine, and it
    is chosen deliberately at space creation (`Nest.Spaces.Space`).

  ## Agent-visible paths do not change

  Whichever backend runs a command, the agent names the same paths. An agent's
  scratch directory is `/tmp/<agent-name>/…` and its workspace is the
  workspace's own path — for bwrap because the space scratch dir is bound at
  `/tmp`, for docker because the container's `/tmp` is the space scratch dir,
  and for `none` because the host's `/tmp` *is* `/tmp`. `Nest.Sandbox.Paths`
  is the one definition of that spelling.
  """

  alias Nest.Sandbox.Mounts

  @typedoc """
  A built invocation: the command line to run, and the directory to run it in
  (`nil` when the command line already sets one — bwrap `--chdir`s itself).
  """
  @type spec :: %{command: String.t(), cd: String.t() | nil}

  @doc """
  The module that runs a call on `mounts`' backend.

  Returns `{:error, reason}` for a backend string this build does not
  implement, so the caller reports it to the agent rather than raising inside a
  tool worker.
  """
  @spec resolve(Mounts.t()) :: {:ok, module()} | {:error, String.t()}
  def resolve(mounts) do
    case Mounts.backend(mounts) do
      "bwrap" -> {:ok, __MODULE__.Bwrap}
      "none" -> {:ok, __MODULE__.None}
      # `docker` is a backend `Nest.Spaces.Space.sandbox_backends/0` offers, so
      # it gets its own clause rather than falling through to the unknown-value
      # error: a space created with it must be told what is actually missing,
      # not that its backend is not a backend. This clause is what
      # `Nest.Sandbox.Backend.Docker` replaces.
      "docker" -> {:error, "The docker sandbox backend is not implemented yet"}
      other -> {:error, "Unknown sandbox backend: #{inspect(other)}"}
    end
  end

  @doc """
  Build the command line that runs `script` (a path in the sandbox domain) on
  `mounts`' backend.
  """
  @spec command(Mounts.t(), map() | nil, String.t()) :: {:ok, spec()} | {:error, String.t()}
  def command(mounts, caps, script) do
    with {:ok, backend} <- resolve(mounts) do
      backend.command(mounts, caps, script)
    end
  end

  @doc """
  The host directory the command transcript is staged in, on `mounts`'
  backend.

  Resolved through `resolve/1` and raised on an unknown backend, because this
  is called from a staging path that has already resolved the backend — an
  unknown value there is a programming error, not a user-facing failure.
  """
  @spec stage_dir(Mounts.t()) :: String.t()
  def stage_dir(mounts), do: backend!(mounts).stage_dir(mounts)

  @doc """
  The spelling of `stage_dir/1` inside the environment the backend builds.
  """
  @spec stage_dir_sandbox(Mounts.t()) :: String.t()
  def stage_dir_sandbox(mounts), do: backend!(mounts).stage_dir_sandbox(mounts)

  @doc """
  How `mounts`' backend is named in an operator log line.
  """
  @spec display_name(Mounts.t()) :: String.t()
  def display_name(mounts), do: backend!(mounts).display_name(mounts)

  @doc """
  Classify a failed command's stderr into an error atom, for `mounts`'
  backend.
  """
  @spec classify(Mounts.t(), String.t()) :: atom()
  def classify(mounts, stderr), do: backend!(mounts).classify(mounts, stderr)

  # A backend string that is not in `Nest.Spaces.Space.sandbox_backends/0` can
  # only come from a row written by a build that had a backend this one does
  # not. `command/3` reports that as an error the agent can read; the four
  # accessors above are reached only after `command/3` has already resolved,
  # so they raise instead of pretending a backend.
  defp backend!(mounts) do
    case resolve(mounts) do
      {:ok, backend} -> backend
      {:error, reason} -> raise ArgumentError, reason
    end
  end
end
