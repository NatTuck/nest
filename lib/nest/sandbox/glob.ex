defmodule Nest.Sandbox.Glob do
  @moduledoc """
  Runs a glob inside bwrap and returns readable regular files in the sandbox
  spelling.

  Kept separate from `Nest.Sandbox` to hold that module under the size cap. The
  matcher is bash (`nullglob globstar dotglob`): bash resolves symlinks and the
  `/tmp` bind exactly as a shell inside the sandbox would, which is the point of
  running the glob in bwrap. Results are re-sorted in Elixir (bash sorts by
  locale).

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one non-`/` char),
  and `**` (any run of path segments when it occupies a full segment). A
  terminal `**` is refused: bash would eagerly expand the whole subtree.
  """

  alias Nest.FSPath
  alias Nest.Sandbox.{Failure, Paths}
  alias Nest.Tools.{ShellCmd, ShellEscape}

  @glob_limit 1_000
  # Bash materialises the whole match list before the loop runs, so the match
  # limit does not bound the *work*. A timeout keeps a pathological pattern
  # (e.g. a huge single directory) from hanging the tool worker.
  @glob_timeout_ms 30_000

  @doc """
  Expand a resolved-against-`workspace` glob `pattern` inside bwrap.

  `opts` accepts `limit:` (default `#{@glob_limit}`), the max number of raw
  matches before the call returns `{:error, :glob_too_broad}`.
  """
  @spec run(String.t(), map(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, [String.t()]} | {:error, atom() | term()}
  def run(pattern, caps, workspace, tmp_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, @glob_limit)

    with {:ok, full} <- FSPath.resolve(pattern, workspace),
         :ok <- reject_terminal_double_star(full) do
      execute(full, caps, workspace, tmp_path, limit)
    end
  end

  defp execute(full, caps, workspace, tmp_path, limit) do
    script = script(shell_glob(full), shell_glob(Paths.stage_dir_sandbox(tmp_path)), limit)

    case ShellCmd.execute_raw(script, workspace, tmp_path, caps, timeout: @glob_timeout_ms) do
      {:ok, 0, stdout, _stderr} ->
        {:ok, stdout |> split_nul() |> Enum.sort() |> Enum.uniq()}

      {:ok, 3, _stdout, _stderr} ->
        {:error, :glob_too_broad}

      {:ok, _exit_code, _stdout, stderr} ->
        reason = Failure.classify(stderr)
        Failure.log(:glob, full, reason, stderr)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `full` is a resolved absolute pattern in the sandbox spelling. Bash resolves
  # symlinks and the `/tmp` bind exactly as a shell inside the sandbox would.
  #
  # Nest stages command transcripts in `Paths.stage_dir_sandbox/1` (visible
  # inside at `/tmp/.cmds`, or at its host spelling when there is no scratch
  # bind). The loop skips that whole directory so Nest's own scripts never
  # appear in results, while a real file an agent names `.nest-cmd-notes.sh` is
  # no longer hidden by a basename-prefix check.
  defp script(escaped_pattern, escaped_stage_dir, limit) do
    """
    export LC_ALL=C
    shopt -s nullglob globstar dotglob
    n=0
    for p in #{escaped_pattern}; do
      case "$p" in #{escaped_stage_dir}/*) continue;; esac
      n=$((n + 1))
      if [ "$n" -gt #{limit} ]; then
        printf 'nest-glob-too-broad\\n' >&2
        exit 3
      fi
      [ -f "$p" ] || continue
      printf '%s\\0' "$p"
    done
    """
  end

  # Single-quote every literal run and leave only `*` and `?` bare, so the
  # shell performs pathname expansion on the glob metacharacters while treating
  # `[`, `]`, `{`, `}`, `\`, `~`, spaces, and quotes literally (matching
  # today's `*`/`?`-only semantics).
  defp shell_glob(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.chunk_by(&(&1 in ["*", "?"]))
    |> Enum.map_join(fn chunk ->
      text = Enum.join(chunk)
      if hd(chunk) in ["*", "?"], do: text, else: ShellEscape.escape(text)
    end)
  end

  defp reject_terminal_double_star(full) do
    if Path.basename(full) == "**" do
      {:error, :glob_terminal_double_star}
    else
      :ok
    end
  end

  defp split_nul(stdout) do
    stdout
    |> String.split(<<0>>, trim: true)
    |> Enum.reject(&(&1 == ""))
  end
end
