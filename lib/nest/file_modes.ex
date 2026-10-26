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

  Not in scope, deliberately: paths a *user* named — a `.nest` mount's `rw`
  destination, the base of `:timeline_dir` (whose per-run directory is created
  under it, but under a path the user chose) — and vendor paths (the HPU log
  directory). Those belong to whoever named them, and Nest narrowing or widening
  them would be a surprise. A `.nest` mount's `tmp` *source* is the opposite case
  and is in scope: it is `<scratch>/project/<slug>`, Nest's own directory, bound
  read-write into the sandbox (`Nest.ProjectConfig.ensure_dirs/1`).

  ## Existing entries

  `mkdir_p/1` and `mkdir_p!/1` set the mode on the directories they *created* and
  leave an existing one alone, so a caller's own `0700` is never widened. A file
  the write helpers touch is Nest's own by construction, so its mode is always
  set.

  Two consequences worth stating, since both are visible from outside:

    * a directory that already existed keeps its mode, so this does not heal one
      created before it existed — an adopted `"none"` scratch at `/tmp/<name>`
      keeps whatever mode it had;
    * the "created" list is computed before the `mkdir_p`, so a level a
      concurrent caller creates in that window is chmod'd too. Harmless here
      (every caller of a given path wants `0755`), but it is why the promise is
      "a caller's own `0700` is not widened" rather than "nothing else is
      touched".

  A `mkdir_p` that succeeds but whose `chmod` fails raises `File.Error` from both
  forms: the directory exists but cannot be made usable, which no caller can act
  on differently from a failure to make it.
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
    # The fast path matters: `Transcript.stage/2` calls this on every `shell-cmd`,
    # and the directory almost always exists by then. One `stat` instead of one
    # per component (the creation branch stats the leaf twice, which is fine —
    # it is the rare one).
    if File.dir?(path) do
      :ok
    else
      created = missing(path)

      with :ok <- File.mkdir_p(path) do
        Enum.each(created, &File.chmod!(&1, @dir_mode))
      end
    end
  end

  @doc """
  `File.mkdir_p!/1`, with `0755` on every directory the call created.

  Returns `:ok`, and raises `File.Error` for a failure to make the directory
  exactly as `File.mkdir_p!/1` does: callers and tests pin that shape, and the
  idiom it trains (`:ok = mkdir_p!(…)`) must not get a `MatchError` instead.
  """
  @spec mkdir_p!(Path.t()) :: :ok
  def mkdir_p!(path) do
    case mkdir_p(path) do
      :ok ->
        :ok

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
