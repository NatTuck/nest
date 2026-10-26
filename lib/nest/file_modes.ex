defmodule Nest.FileModes do
  @moduledoc """
  The modes for the files and directories Nest creates itself.

  A *command's* modes come from the transcript's `umask` preamble
  (`Nest.Tools.ShellCmd.Transcript`), which is why every command creates `0755`
  directories and `0644` files whatever the launcher's umask was (#171). Files
  and directories **Nest** creates have no such seam: the BEAM has no umask
  setter, and bwrap, `docker exec` and a bare fork all inherit rather than accept
  one — so under a launcher with umask `000`, `File.mkdir_p!("/tmp/<agent>")`
  makes a `0777` directory. A world-writable directory in shared temp space is a
  symlink-attack surface, and the agent's scratch directory is exactly that.

  So the mode is applied *after* creation, here and nowhere else: directories
  `0755`, files `0644` — the same rule the transcript preamble gives a command, so
  the two cannot disagree.

  ## What is in scope

  The directories Nest owns in shared temp space: the scratch root, a space's
  directory, an agent's directory, the staging directory, `shell-jobs/`, the
  docker staging directory, and the files inside them (markers, stamps, job logs,
  offloads, staged transcripts).

  Not in scope, deliberately: paths a *user* configured (`:timeline_dir`, a
  `.nest` mount source or destination) and vendor paths (the HPU log directory).
  Those belong to whoever named them, and Nest narrowing or widening them would be
  a surprise — a caller that wants a mode there should set it itself.

  ## Existing entries

  `mkdir_p/1` and `mkdir_p!/1` set the mode on the directories they *created* and
  leave an existing one alone, so a caller's own `0700` is never widened. A file
  the write helpers touch is Nest's own by construction, so its mode is always
  set.
  """

  @dir_mode 0o755
  @file_mode 0o644

  @doc """
  `File.mkdir_p/1`, with `0755` on every directory the call created.

  The levels are the ones that did not exist before the call, so a parent that
  was already there keeps its mode.
  """
  @spec mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_p(path) do
    created = missing(path)

    with :ok <- File.mkdir_p(path) do
      Enum.each(created, &File.chmod!(&1, @dir_mode))
    end
  end

  @doc """
  `File.mkdir_p!/1`, with `0755` on every directory the call created.

  Raises `File.Error` exactly as `File.mkdir_p!/1` does — callers and tests pin
  that shape — and returns `path` rather than `:ok`, because every caller here is
  making a directory it is about to hand back or join onto.
  """
  @spec mkdir_p!(Path.t()) :: Path.t()
  def mkdir_p!(path) do
    case mkdir_p(path) do
      :ok ->
        path

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "make directory (with -p)",
          path: IO.chardata_to_string(path)
    end
  end

  @doc """
  `File.write/2`, with `0644` on the file.
  """
  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, contents) do
    with :ok <- File.write(path, contents) do
      File.chmod(path, @file_mode)
    end
  end

  @doc """
  `File.write!/2`, with `0644` on the file.

  Raises `File.Error` exactly as `File.write!/2` does.
  """
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, contents) do
    case write(path, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "write to file",
          path: IO.chardata_to_string(path)
    end
  end

  # The components of `path` that do not exist yet, shallowest first — exactly
  # what `File.mkdir_p/1` creates.
  defp missing(path) do
    path
    |> Path.split()
    |> Enum.reduce({nil, []}, fn part, {parent, acc} ->
      full = if parent, do: Path.join(parent, part), else: part
      {full, if(File.exists?(full), do: acc, else: [full | acc])}
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
