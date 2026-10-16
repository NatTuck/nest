defmodule Nest.Sandbox.StatBatch do
  @moduledoc """
  Batched `stat` for the BatchSizer preflight (issue #48).

  `Nest.Sandbox.stat/3` is one sandbox spawn per path. The preflight needs only a
  size per `file-read` target, so `stat_many/3` runs **one** `stat` invocation
  per chunk of paths — far fewer spawns than one per path, and still no
  host-side fast path: the command runs inside the sandbox through
  `Nest.Tools.ShellCmd.execute_raw/4`, and the bind layout stays in
  `Nest.Sandbox.Paths`.

  The one case that does not collapse: a chunk that is mostly *absent* degrades
  to one `stat/3` per absent path, because each absent path needs its own
  reason and log line. 150 present + 5 missing paths cost 7 spawns (two chunk
  invocations plus the five fallbacks), not 2 — still bounded by the number of
  absent paths rather than by the batch.

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
      `Nest.Sandbox.stat/3`, so each keeps its own `Nest.Sandbox.Backend.classify/2` reason
      and its own operator log line.
    * Nothing reported at all — the sandbox itself failed, so the stderr is
      classified once and applied to every path in the chunk, with a single log
      line (the chunk's first path stands in for the batch).
    * A path containing a newline cannot ride line-framed output and is statted
      individually.
  """

  alias Nest.Sandbox
  alias Nest.Sandbox.{Backend, Failure, Mounts}
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellEscape

  # The most paths one invocation may carry. Keeps the command line far under
  # `ARG_MAX`; a larger batch takes several invocations, still far fewer than
  # one per path.
  @chunk 100

  @doc """
  The size of every distinct path in `paths`, in as few sandbox spawns as
  possible.

  Returns `%{path => {:ok, size} | {:error, reason}}`.
  """
  @spec stat_many([String.t()], map(), Mounts.t()) ::
          %{required(String.t()) => {:ok, non_neg_integer()} | {:error, atom() | term()}}
  def stat_many(paths, caps, mounts) do
    paths
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      Map.merge(acc, stat_chunk(chunk, caps, mounts))
    end)
  end

  # One chunk, in one sandbox spawn where possible.
  defp stat_chunk(chunk, caps, mounts) do
    {batched, unbatched} = Enum.split_with(chunk, &(not String.contains?(&1, "\n")))

    batched
    |> run_batch(caps, mounts)
    |> Map.merge(per_path_sizes(unbatched, caps, mounts))
  end

  defp run_batch([], _caps, _mounts), do: %{}

  defp run_batch(paths, caps, mounts) do
    case ShellCmd.execute_raw(stat_command(paths), mounts, caps) do
      {:ok, _exit_code, "", stderr} ->
        whole_chunk_failed(paths, stderr, mounts)

      {:ok, _exit_code, stdout, _stderr} ->
        partial(paths, stdout, caps, mounts)

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
  #
  # Attribution here is therefore chunk-level: where a chunk's paths would have
  # failed for different reasons, the per-path `reason` and log line differ from
  # what a per-path `stat/4` would have produced. That is a `reason`/logging
  # detail only — the preflight projects every error identically, so no refusal
  # decision moves. Attribution is exact on the fallback path
  # (`per_path_sizes/4`).
  defp whole_chunk_failed(paths, stderr, mounts) do
    reason = Backend.classify(mounts, stderr)
    Failure.log(:stat, "#{hd(paths)} (+#{length(paths) - 1} more)", reason, stderr)
    Map.new(paths, &{&1, {:error, reason}})
  end

  # Map the reported paths back by name and re-stat whatever is absent, so each
  # rejected path keeps its own reason and its own log line. Nothing is absent
  # when `stat` exited 0; this also keeps the "an entry for every path"
  # contract when a line is unparseable.
  defp partial(paths, stdout, caps, mounts) do
    reported = parse(stdout)
    missing = Enum.reject(paths, &Map.has_key?(reported, &1))
    Map.merge(reported, per_path_sizes(missing, caps, mounts))
  end

  # The per-path fallback: exactly what `Nest.Sandbox.stat/3` does, including
  # its reason classification and operator logging.
  defp per_path_sizes(paths, caps, mounts) do
    Map.new(paths, fn path ->
      case Sandbox.stat(path, caps, mounts) do
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
