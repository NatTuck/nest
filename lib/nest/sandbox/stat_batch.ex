defmodule Nest.Sandbox.StatBatch do
  @moduledoc """
  Batched `stat` for the BatchSizer preflight (issue #48).

  `Nest.Sandbox.stat/4` is one bwrap spawn per path. The preflight needs only a
  size per `file-read` target, so `stat_many/4` runs **one** `stat` invocation
  per chunk of paths — far fewer spawns than one per path, and still no
  host-side fast path: the command runs inside bwrap through
  `Nest.Tools.ShellCmd.execute_raw/5`, and the path mapping stays in
  `Nest.Sandbox.Paths`.

  ## Framing

  The command is

      LC_ALL=C stat -L -c '%s|%Y|%f|%n' -- <escaped path> ...

  `%n` is **last** so a path containing `|` cannot break the framing: each
  reported file yields one `size|mtime|mode|path` line with the path as the
  remainder. A rejected path (missing, denied) prints only to stderr and the
  invocation exits non-zero, so the parse maps stdout by name and re-stats
  whatever is absent.

  ## Failure handling

    * Some paths reported, some not — the absent ones are re-statted with
      `Nest.Sandbox.stat/4`, so each keeps its own `Failure.classify/1` reason
      and its own operator log line.
    * Nothing reported at all — the sandbox itself failed, so the stderr is
      classified once and applied to every path in the chunk, with a single log
      line (the chunk's first path stands in for the batch).
    * A path containing a newline cannot ride line-framed output and is statted
      individually.
  """

  alias Nest.Sandbox
  alias Nest.Sandbox.Failure
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellEscape

  # The most paths one invocation may carry. Keeps the command line far under
  # `ARG_MAX`; a larger batch takes several invocations, still far fewer than
  # one per path.
  @chunk 100

  @doc """
  The size of every distinct path in `paths`, in as few bwrap spawns as
  possible.

  Returns `%{path => {:ok, size} | {:error, reason}}`.
  """
  @spec stat_many([String.t()], map(), String.t() | nil, String.t() | nil) ::
          %{required(String.t()) => {:ok, non_neg_integer()} | {:error, atom() | term()}}
  def stat_many(paths, caps, workspace, tmp_path) do
    paths
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      Map.merge(acc, stat_chunk(chunk, caps, workspace, tmp_path))
    end)
  end

  # One chunk, in one bwrap spawn where possible.
  defp stat_chunk(chunk, caps, workspace, tmp_path) do
    {batched, unbatched} = Enum.split_with(chunk, &(not String.contains?(&1, "\n")))

    batched
    |> run_batch(caps, workspace, tmp_path)
    |> Map.merge(per_path_sizes(unbatched, caps, workspace, tmp_path))
  end

  defp run_batch([], _caps, _workspace, _tmp_path), do: %{}

  defp run_batch(paths, caps, workspace, tmp_path) do
    case ShellCmd.execute_raw(stat_command(paths), workspace, tmp_path, caps) do
      {:ok, _exit_code, "", stderr} ->
        whole_chunk_failed(paths, stderr)

      {:ok, _exit_code, stdout, _stderr} ->
        partial(paths, stdout, caps, workspace, tmp_path)

      {:error, reason} ->
        Map.new(paths, &{&1, {:error, reason}})
    end
  end

  # `%n` is last so a path containing `|` cannot break the framing.
  defp stat_command(paths) do
    "LC_ALL=C stat -L -c '%s|%Y|%f|%n' -- " <>
      Enum.map_join(paths, " ", &ShellEscape.escape/1)
  end

  # No output at all: the sandbox itself failed, so every path in the chunk
  # shares one reason and one log line instead of one of each per path.
  defp whole_chunk_failed(paths, stderr) do
    reason = Failure.classify(stderr)
    Failure.log(:stat, hd(paths), reason, stderr)
    Map.new(paths, &{&1, {:error, reason}})
  end

  # Map the reported paths back by name and re-stat whatever is absent, so each
  # rejected path keeps its own reason and its own log line. Nothing is absent
  # when `stat` exited 0; this also keeps the "an entry for every path"
  # contract when a line is unparseable.
  defp partial(paths, stdout, caps, workspace, tmp_path) do
    reported = parse(stdout)
    missing = Enum.reject(paths, &Map.has_key?(reported, &1))
    Map.merge(reported, per_path_sizes(missing, caps, workspace, tmp_path))
  end

  # The per-path fallback: exactly what `Nest.Sandbox.stat/4` does, including
  # its reason classification and operator logging.
  defp per_path_sizes(paths, caps, workspace, tmp_path) do
    Map.new(paths, fn path ->
      case Sandbox.stat(path, caps, workspace, tmp_path) do
        {:ok, %File.Stat{size: size}} -> {path, {:ok, size}}
        {:error, reason} -> {path, {:error, reason}}
      end
    end)
  end

  # One `size|mtime|mode|path` line per file `stat` reported. The path is the
  # remainder of the line, so it survives an embedded `|`.
  defp parse(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      with [size, _mtime, _mode, path] <- String.split(line, "|", parts: 4),
           {n, ""} <- Integer.parse(size) do
        Map.put(acc, path, {:ok, n})
      else
        _ -> acc
      end
    end)
  end
end
