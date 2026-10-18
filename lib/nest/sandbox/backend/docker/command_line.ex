defmodule Nest.Sandbox.Backend.Docker.CommandLine do
  @moduledoc """
  The command line a docker call runs, as text.

  Two shell layers read it: the BEAM's command parser, which sees the whole thing
  as one quoted argument, and the container's bash, which runs it. Every path is
  escaped for the second, and the whole payload for the first.

  Split out of `Nest.Sandbox.Backend.Docker` so that module stays under the
  file-length cap. Nothing here decides *what* to run — that is the backend's
  call, and it hands this module the caps and the script — only how the result is
  spelled.
  """

  alias Nest.FSPath
  alias Nest.Sandbox.{Binds, Mounts, Paths}
  alias Nest.Tools.ShellEscape

  # The flags the sandbox *inside* the container runs with. `--ro-bind / /` makes
  # the whole image read-only, and each bind the call's caps ask for is re-applied
  # as a self-bind, which is what sets that path's mode. One exception: an absent
  # `.nest`/`AGENTS.md` is bound from `/dev/null`, because the container does not
  # bind those two at all (`Binds.container_specs/1`).
  @inner_flags ~w(--die-with-parent --new-session --ro-bind / / --dev-bind /dev /dev --proc /proc)

  @doc """
  `docker exec` for `script`, with the sandbox inside tightened to this call's
  caps. `log_path` is `nil` for a foreground call and the job's log inside the
  container for a background one.
  """
  @spec exec_line(String.t(), Mounts.t(), map(), String.t(), String.t() | nil) :: String.t()
  def exec_line(name, mounts, caps, script, log_path) do
    "docker exec -i #{name} /bin/bash -c " <>
      ShellEscape.escape(payload(mounts, caps, script, log_path))
  end

  @doc """
  The workspace at the path the *caller* named, when the shared bind list uses a
  different one.

  `Nest.Sandbox.Binds` binds the canonical path, and under bwrap the caller's
  spelling still resolves — the host's `/` is bound read-only underneath it, so
  the kernel follows the symlink to the writable bind. A container sees only the
  image and the explicit binds, so nothing resolves it, and every path the model
  was given names that spelling. So the container materializes it, and the sandbox
  inside re-binds it with the call's own mode, making a write through either
  spelling equally writable.
  """
  @spec workspace_spelling(Mounts.t(), :rw | :ro) :: [Binds.spec()]
  def workspace_spelling(%Mounts{workspace: nil}, _mode), do: []

  def workspace_spelling(%Mounts{workspace: workspace}, mode) do
    if FSPath.canonical(workspace) == workspace do
      []
    else
      [{workspace, workspace, mode}]
    end
  end

  # The script the container's bash runs.
  defp payload(mounts, caps, script, log_path) do
    pipefail = if log_path, do: "set -o pipefail; ", else: ""

    pipefail <>
      mkdir_prefix(mounts, log_path) <>
      "exec " <> sandbox_line(mounts, caps, script) <> tee_suffix(log_path)
  end

  # The agent's scratch directory is the container's own `/tmp/<agent>`, so the
  # command that runs is what makes it — nothing on the host can.
  defp mkdir_prefix(mounts, log_path) do
    dirs =
      [Mounts.scratch(mounts), log_path && Path.dirname(log_path)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case dirs do
      [] -> ""
      dirs -> "mkdir -p " <> Enum.map_join(dirs, " ", &ShellEscape.escape/1) <> " && "
    end
  end

  defp tee_suffix(nil), do: ""

  defp tee_suffix(log_path) do
    " 2>&1 | tee " <> ShellEscape.escape(log_path)
  end

  defp sandbox_line(mounts, caps, script) do
    protected = MapSet.new(Binds.protected_specs(caps))
    spelling = workspace_spelling(mounts, Binds.workspace_mode(caps))

    binds =
      (Binds.specs(caps, mounts) ++ spelling)
      |> Enum.flat_map(&inner_bind(&1, MapSet.member?(protected, &1)))

    args =
      @inner_flags ++
        binds ++
        spelling_masks(spelling, caps) ++
        ["--chdir", ShellEscape.escape(chdir(mounts))] ++
        ["/bin/bash", ShellEscape.escape(script)]

    Enum.join(["bwrap" | args], " ")
  end

  # The protected masks again, re-dest'd at the workspace's **own spelling**.
  #
  # `Binds.specs/2` binds the workspace at its canonical path, symlinks resolved,
  # and that is where the `.nest`/`AGENTS.md` masks point. `workspace_spelling/2`
  # then binds the path the caller named as well whenever it differs, because the
  # container sees only the image and the explicit binds — nothing resolves a
  # symlink for it. Two binds of one directory is two writable views of it, so a
  # mask at the canonical path leaves `<spelling>/.nest` an ordinary writable
  # file, at the very path `--chdir`, the prompt and every tool path use: an `act`
  # agent writes it, the host file stays a regular file, and the `ShellCmd` gate
  # has nothing to refuse. These masks are rendered *after* the spelling self-bind
  # so they win. (Under bwrap there is no second bind — the alias stays a symlink
  # into the masked canonical mount — so this is docker's alone.)
  defp spelling_masks([], _caps), do: []

  defp spelling_masks([{spelling, _dest, _mode} | _rest], caps) do
    Enum.flat_map(Binds.protected_specs(caps), fn {source, dest, _ro} ->
      [
        "--ro-bind",
        ShellEscape.escape(source),
        ShellEscape.escape(Path.join(spelling, Path.basename(dest)))
      ]
    end)
  end

  # The one exception, and it is the `.nest`/`AGENTS.md` mask: the container does
  # *not* bind those (`Binds.container_specs/1`), so there is no source at
  # the dest to set the mode of. An absent file is masked with `/dev/null` here
  # instead of self-bound, which is exactly what the bwrap backend does — and it
  # is why reading a masked file fails with `EACCES` rather than returning empty
  # bytes, `--ro-bind` mounting with `nodev`. `/dev/null` is there because
  # `--dev-bind /dev /dev` is one of the flags above.
  defp inner_bind({"/dev/null", dest, :ro}, true) do
    ["--ro-bind", "/dev/null", ShellEscape.escape(dest)]
  end

  # The container has already put this bind's source at its `dest`, so what the
  # sandbox inside has to do is set the *mode* of that path: `--ro-bind / /` made
  # everything read-only, and a read-only bind cannot be upgraded from inside.
  # A self-bind is exactly "set this path's mode", and bwrap applies it to the
  # mount that is already there.
  defp inner_bind({_source, dest, mode}, _protected) do
    [bind_flag(mode), ShellEscape.escape(dest), ShellEscape.escape(dest)]
  end

  defp bind_flag(:rw), do: "--bind"
  defp bind_flag(:ro), do: "--ro-bind"

  # No workspace means "start in the scratch root", exactly as bwrap's own
  # `--chdir` does when it has a scratch bind and no workspace.
  defp chdir(%Mounts{workspace: nil}), do: Paths.sandbox_root()
  defp chdir(%Mounts{workspace: workspace}), do: workspace
end
