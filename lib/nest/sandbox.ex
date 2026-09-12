defmodule Nest.Sandbox do
  @moduledoc """
  The single, authoritative gatekeeper for all agent file access.

  Everything an agent reads, writes, stats, or executes goes through
  this module. It has three facets:

  ## Rule helpers (shared single source of truth)

  `readable_roots/1`, `writable_roots/2`, `read_allowed?/2`,
  `write_allowed?/3`, and `resolve/2` are pure predicates built on
  `Nest.FSPath` (canonicalization + containment). These are the ONLY
  place the sandbox rules live: the bwrap argument builder derives its
  mounts from them, and the read-only host fast-path authorizes from
  them, so the fast-path can never permit something the mounts deny
  (and vice-versa).

  ## bwrap argument builder

  `build/3` and `build/4` translate caps into a bwrap command line.
  Paths are canonicalized (symlinks resolved) for bind *mounts* so a
  symlink-traversing workspace binds to its real target; `--chdir`
  stays on the user-provided path so the LLM and tools keep addressing
  files exactly as the user gave them.

  ## Executors

  `read/3` and `stat/4` are read-only fast-paths: they authorize via
  the shared helpers and then hit the host filesystem directly, so
  bwrap is not spawned for pure reads. Because bwrap runs as the same
  uid with no uid remap and binds paths derived from the same helpers,
  a host read is byte- and permission-identical to what bwrap would
  expose. `write/5` and `run/5` always go through bwrap (`ShellCmd`),
  so write/execute permissions are enforced by the mounts.

  ## Caps shape

  Caps are a raw map matching the JSONB shape stored on
  `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{
          "read" => [String.t()],
          "write" => [String.t()]
        }
      }

  * `"net"` — when `true`, the sandbox shares the host's network
    namespace (`--share-net`); when `false`, network is unshared.
  * `"fs.read"` — must include `"/"` to run any command. `["/"]`
    produces `--ro-bind / /`.
  * `"fs.write"` — the explicit list of paths bound read-write. The
    `":workspace"` and `"/tmp"` entries are symbolic (resolved to the
    canonical workspace and the per-agent scratch dir); any other path
    is bound at its canonical path. Anything not in the write list
    stays read-only via `--ro-bind / /`.

  ## Missing paths

  A non-existent workspace is rejected before bwrap runs (bwrap never
  creates it). A non-existent `fs.write` path fails at bwrap time as a
  missing source rather than being created: any operation that would
  fail on a missing directory fails, it is never auto-created.
  """

  alias Nest.FSPath
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellEscape

  @doc """
  The default "build" profile (full host read, workspace + /tmp
  writable, no network). Used by callers that haven't been migrated to
  pass real caps (and as the fallback in `ShellCmd.execute/5`).
  """
  @spec default_caps() :: map()
  def default_caps do
    %{
      "net" => false,
      "fs" => %{
        "read" => ["/"],
        "write" => ["/tmp", ":workspace"]
      }
    }
  end

  @doc """
  Build bwrap args using `default_caps/0`.
  """
  @spec build_default(String.t(), String.t() | nil) :: {:ok, [String.t()]}
  def build_default(workspace_path, tmp_path) do
    {:ok, args} = build(default_caps(), workspace_path, tmp_path)
    {:ok, args}
  end

  @doc """
  Build the bwrap argument list for the given caps, workspace, and tmp
  path. The workspace is bound at its canonical (symlink-resolved)
  path and `--chdir` targets `workspace_path` (the user-provided path).
  """
  @spec build(map(), String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path) do
    build(caps, workspace_path, tmp_path, workspace_path)
  end

  @doc """
  Build bwrap args, binding the workspace (canonicalized) while
  `--chdir`-ing to `chdir_path`. `chdir_path` lets callers keep the
  user-facing workspace path while the mount uses the canonical one.
  """
  @spec build(map(), String.t(), String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path, chdir_path) do
    with :ok <- validate_caps(caps) do
      args =
        base_args(caps)
        |> append_net_flag(caps)
        |> append_workspace_bind(caps, workspace_path)
        |> append_write_binds(caps, workspace_path)
        |> append_tmp_bind(tmp_path)
        |> append_chdir(chdir_path)

      {:ok, args}
    end
  end

  @doc """
  Validates a caps map. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_caps(map()) :: :ok | {:error, String.t()}
  def validate_caps(%{"net" => net, "fs" => %{"read" => read, "write" => write}})
      when is_boolean(net) and is_list(read) and is_list(write) do
    cond do
      "/" not in read ->
        {:error, "caps.fs.read must include \"/\" (bwrap needs /bin/sh)"}

      not Enum.all?(read, &is_binary/1) ->
        {:error, "caps.fs.read entries must be strings"}

      not Enum.all?(write, &is_binary/1) ->
        {:error, "caps.fs.write entries must be strings"}

      true ->
        :ok
    end
  end

  def validate_caps(%{"net" => _, "fs" => %{"read" => _, "write" => write}})
      when not is_list(write) do
    {:error, "caps.fs.write must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"read" => read, "write" => _}})
      when not is_list(read) do
    {:error, "caps.fs.read must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"read" => _}}) do
    {:error, "caps.fs.write must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => %{"write" => _}}) do
    {:error, "caps.fs.read must be a list"}
  end

  def validate_caps(%{"net" => _, "fs" => _}) do
    {:error, "caps.fs must be a map with \"read\" (list) and \"write\" (list) keys"}
  end

  def validate_caps(%{"net" => _}) do
    {:error, "caps.fs is required"}
  end

  def validate_caps(%{"fs" => _}) do
    {:error, "caps.net is required"}
  end

  def validate_caps(caps) do
    {:error, "invalid caps: #{inspect(caps)}"}
  end

  # ---- Rule helpers (shared single source of truth) ----

  @doc """
  The canonical host paths the sandbox exposes read-only (from
  `caps.fs.read`).
  """
  @spec readable_roots(map()) :: [String.t()]
  def readable_roots(caps) do
    caps |> read_list() |> Enum.map(&FSPath.canonical/1) |> Enum.uniq()
  end

  @doc """
  The canonical host paths the sandbox exposes read-write: the
  canonical workspace (when `:workspace` is in the write list) plus
  each extra `fs.write` path, canonicalized and deduplicated. The
  `"/tmp"` entry is excluded here because it is bound at `/tmp` inside
  the sandbox, not at a user-facing host path.
  """
  @spec writable_roots(map(), String.t() | nil) :: [String.t()]
  def writable_roots(caps, workspace) do
    writes = write_list(caps)

    workspace_root =
      if ":workspace" in writes and is_binary(workspace),
        do: [FSPath.canonical(workspace)],
        else: []

    extras =
      writes |> Enum.reject(&(&1 in [":workspace", "/tmp"])) |> Enum.map(&FSPath.canonical/1)

    (workspace_root ++ extras) |> Enum.uniq()
  end

  @doc """
  True when `path` is readable under `caps` — i.e. its canonical path
  lies beneath a readable root. Produces the same result bwrap's
  read-only binds would.
  """
  @spec read_allowed?(String.t(), map()) :: boolean()
  def read_allowed?(path, caps) do
    canonical = FSPath.canonical(path)
    Enum.any?(readable_roots(caps), &FSPath.under?(&1, canonical))
  end

  @doc """
  True when `path` is writable under `caps` — i.e. its canonical path
  lies beneath a writable root (canonical workspace or an extra write
  path). Produces the same result bwrap's read-write binds would.
  """
  @spec write_allowed?(String.t(), map(), String.t() | nil) :: boolean()
  def write_allowed?(path, caps, workspace) do
    canonical = FSPath.canonical(path)
    Enum.any?(writable_roots(caps, workspace), &FSPath.under?(&1, canonical))
  end

  @doc """
  Resolve a tool path against the workspace root (see `Nest.FSPath.resolve/2`).
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, workspace), do: FSPath.resolve(path, workspace)

  # ---- Executors ----

  @doc """
  Read `path` after authorizing it via `read_allowed?/2`. Uses the
  read-only host fast-path (no bwrap). Returns `{:ok, content}`,
  `{:error, reason}`, or `{:error, :read_permission_denied}`.
  """
  @spec read(String.t(), map(), keyword()) :: {:ok, binary()} | {:error, atom() | term()}
  def read(path, caps, _opts \\ []) do
    if read_allowed?(path, caps) do
      File.read(path)
    else
      {:error, :read_permission_denied}
    end
  end

  @doc """
  Stat `path` after authorizing it via `read_allowed?/2`. Uses the
  read-only host fast-path (no bwrap). `opts` are passed to
  `File.stat/2` (e.g. `time: :posix`). Returns `{:ok, stat}`,
  `{:error, reason}`, or `{:error, :read_permission_denied}`.
  """
  @spec stat(String.t(), map(), keyword()) :: {:ok, File.Stat.t()} | {:error, atom() | term()}
  def stat(path, caps, opts \\ []) do
    if read_allowed?(path, caps) do
      File.stat(path, opts)
    else
      {:error, :read_permission_denied}
    end
  end

  # Hard ceiling on how many files `glob/4` will expand. A glob is a
  # scatter target (e.g. `agents-batch`); an unbounded match count would
  # fork unbounded children, so we cap expansion and surface a
  # `:glob_too_broad` error so a caller can tell the model to narrow it.
  @glob_limit 1_000

  @doc """
  Expand a glob `pattern` to readable regular files, honoring the same
  read caps as `read/3`. The pattern is resolved against `workspace`
  (an absolute pattern is used as-is), expanded on the host filesystem,
  filtered to regular files whose canonical path is readable under
  `caps`, then returned sorted and deduplicated.

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one
  non-`/` char), and `**` (any run of path segments, including none —
  matched across directory boundaries when it occupies a full segment).

  `opts` accepts `limit:` (default `@glob_limit`), the max number of
  files the pattern may match before the call returns
  `{:error, :glob_too_broad}` (so a scatter caller can ask the model to
  narrow the pattern rather than fork an bounded set). A resolve
  failure for a relative pattern with no workspace returns
  `{:error, reason}`.
  """
  @spec glob(String.t(), map(), String.t() | nil, keyword()) ::
          {:ok, [String.t()]} | {:error, atom() | term()}
  def glob(pattern, caps, workspace, opts \\ []) when is_binary(pattern) and is_map(caps) do
    limit = Keyword.get(opts, :limit, @glob_limit)

    with {:ok, full} <- FSPath.resolve(pattern, workspace) do
      # `do_glob_walk/4` `throw`s `:glob_too_broad` when the match count
      # exceeds the limit (unwinding the recursion early). The per-segment
      # matcher is total (it never raises on a malformed pattern), so this
      # `:error` arm is a defensive backstop: translate any unexpected error
      # into a `:invalid_glob` result rather than crashing the agent's tool
      # worker. `e` may be a raw (non-exception) term, so `inspect` it.
      try do
        {:ok, collect_matches(full, caps, limit)}
      catch
        :throw, :glob_too_broad -> {:error, :glob_too_broad}
        :error, e -> {:error, {:invalid_glob, inspect(e)}}
      end
    end
  end

  # Expand a resolved absolute glob `full` to readable regular files:
  # walk the pattern, keep only files whose canonical path is readable
  # under `caps`, then sort + dedupe. `do_glob_walk/4` may `throw`
  # `:glob_too_broad` from here (propagated to the caller's `catch`).
  defp collect_matches(full, caps, limit) do
    {base_dir, rest} = split_glob_segments(full)

    base_dir
    |> do_glob_walk(rest, [], limit)
    |> Enum.filter(fn path -> File.regular?(path) and read_allowed?(path, caps) end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  # Split a resolved absolute glob pattern into a `{base_dir, rest}`
  # pair. `base_dir` is the longest leading literal prefix (no `*` or
  # `?`), canonicalized via `realpath` so the walk starts at the real
  # directory; `rest` are the remaining glob segments. The leading empty
  # segment of an absolute path is preserved so `Path.join/1` yields the
  # absolute base. When the pattern's first segment is itself a glob,
  # the base collapses to the filesystem root.
  defp split_glob_segments(full) do
    segments = String.split(full, "/", trim: false)

    # The leading literal prefix (up to the FIRST glob segment) is the base
    # directory; everything from the first glob onward is `rest`. `split_while`
    # (unlike `split_with`) stops at the first glob, so a pattern like
    # `src/*/file.txt` keeps `file.txt` in `rest` — `do_glob_walk/4` matches
    # any later literal segment exactly via `fnmatch?/2`.
    {literal, glob} = Enum.split_while(segments, &(!glob_segment?(&1)))

    # `Path.join/1` drops the leading empty segment of an absolute path
    # (`["", "tmp", "x"]` → `"tmp/x"`), which would silently turn the base
    # into a CWD-relative path. Re-prepend `/` when the source was absolute.
    base =
      literal
      |> Path.join()
      |> maybe_make_absolute?(full)

    {base_dir_or_root(base), glob}
  end

  # Re-absolute a base that lost its leading `/` during `Path.join/1`.
  defp maybe_make_absolute?(base, full) do
    if String.starts_with?(full, "/") and not String.starts_with?(base, "/") do
      "/" <> base
    else
      base
    end
  end

  # The literal prefix joined is a full path; canonicalize it, falling
  # back to the root when it's empty (pattern starts with a glob).
  defp base_dir_or_root(""), do: "/"

  defp base_dir_or_root(path), do: FSPath.canonical(path)

  # A segment is a "glob" when it contains `*` or `?`.
  defp glob_segment?(seg), do: String.contains?(seg, "*") or String.contains?(seg, "?")

  # All segments consumed: the current `dir` is a full match.
  defp do_glob_walk(dir, [], acc, limit) do
    acc = [dir | acc]
    if length(acc) > limit, do: throw(:glob_too_broad)
    acc
  end

  # `**` occupies a full segment: match zero or more path segments.
  # We try each remaining segment against the directory contents and
  # recurse both one-level-deeper (into each subdir) and skipping
  # (treating `**` as matching zero segments).
  defp do_glob_walk(dir, ["**" | rest], acc, limit) do
    entries = safe_readdir(dir)

    # `**` may match zero segments: continue with `rest` in the same dir.
    acc = do_glob_walk(dir, rest, acc, limit)

    # `**` matches one-or-more segments: recurse into each subdir.
    acc =
      Enum.reduce(entries, acc, fn name, a ->
        child = Path.join(dir, name)

        if File.dir?(child) do
          do_glob_walk(child, ["**" | rest], a, limit)
        else
          a
        end
      end)

    acc
  end

  # A normal segment: match it against the directory contents.
  defp do_glob_walk(dir, [seg | rest], acc, limit) do
    entries = safe_readdir(dir)

    Enum.reduce_while(entries, acc, fn name, a ->
      if fnmatch?(seg, name) do
        child = Path.join(dir, name)
        {:cont, do_glob_walk(child, rest, a, limit)}
      else
        {:cont, a}
      end
    end)
  end

  # Return the directory's entries as basenames, or `[]` when the
  # directory doesn't exist / isn't readable (the glob simply matches
  # nothing there).
  defp safe_readdir(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # Match a single glob segment (no `/`) against a basename. Supports
  # `*` (any run of characters) and `?` (exactly one character); every
  # other character is literal. `**` never reaches here — it occupies a
  # whole path segment and is handled by its own `do_glob_walk/4` clause.
  defp fnmatch?(pat, name), do: seg_match(pat, name)

  # Both exhausted: matched.
  defp seg_match(<<>>, <<>>), do: true
  # Pattern exhausted but name remains: only matches if the leftover
  # pattern was all stars (handled by the `*` clause below).
  defp seg_match(<<>>, _name), do: false
  # Name exhausted with a non-empty pattern remaining: no match (a
  # trailing `*` was already collapsed into the `*` clause).
  defp seg_match(_pat, <<>>), do: false
  # Leading `*`: collapse consecutive stars, then let the star consume
  # 0..N characters of the name.
  defp seg_match(<<"*"::utf8, rest::binary>>, name) do
    star_match(skip_stars(rest), name)
  end

  # `?` matches any single character.
  defp seg_match(<<"?"::utf8, rest::binary>>, <<_c::utf8, name_rest::binary>>) do
    seg_match(rest, name_rest)
  end

  # Literal character match.
  defp seg_match(<<p::utf8, rest::binary>>, <<n::utf8, name_rest::binary>>) when p == n do
    seg_match(rest, name_rest)
  end

  defp seg_match(_pat, _name), do: false

  # The star has consumed `k` characters of `name`; try to match the
  # remainder of the pattern (`rest`) against the leftover name. The
  # star may consume zero characters first, then one more, etc.
  defp star_match(rest, name) do
    if seg_match(rest, name) do
      true
    else
      case name do
        <<_c::utf8, name_rest::binary>> -> star_match(rest, name_rest)
        <<>> -> false
      end
    end
  end

  # Collapse consecutive leading stars into one (they're redundant).
  defp skip_stars(<<"*"::utf8, rest::binary>>), do: skip_stars(rest)
  defp skip_stars(seg), do: seg

  @doc """
  Run `command` inside the bwrap sandbox. Authorizes nothing further
  itself — the mounts enforce filesystem rules. Delegates to
  `ShellCmd.execute/5`.
  """
  @spec run(String.t(), String.t() | nil, String.t() | nil, map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(command, workspace, tmp_path, caps, opts \\ []) do
    ShellCmd.execute(command, workspace, tmp_path, caps, opts)
  end

  @doc """
  Write `content` to `path` inside the bwrap sandbox. Write
  permissions are enforced by the bind mounts (which are derived from
  `writable_roots/2`), so a write outside the permitted paths fails at
  the kernel level (read-only file system) rather than being
  pre-authorized here. Returns `{:ok, output}` or `{:error, reason}`.
  """
  @spec write(String.t(), binary(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def write(path, content, caps, workspace, tmp_path) do
    ShellCmd.execute(
      "cat > #{ShellEscape.escape(path)}",
      workspace,
      tmp_path,
      caps,
      stdin: content
    )
  end

  # ---- Internal arg-builder helpers ----

  defp base_args(caps) do
    read_args =
      caps
      |> readable_roots()
      |> Enum.flat_map(fn root -> ["--ro-bind", root, root] end)

    # Read-only bind of the readable roots. Must come BEFORE
    # --dev/--proc so the devtmpfs overlays it and /proc/self stays
    # writable inside the sandbox.
    # Fresh devtmpfs over the read-only bind. Makes /dev/null,
    # /dev/zero, etc. writable for shell redirects.
    # Mount the host's procfs after the read-only root bind so that
    # /proc/self/<pid>/... files stay writable inside the sandbox.
    [
      # Unshare everything by default; re-share net below if requested.
      "--unshare-all",
      "--die-with-parent",
      "--new-session"
    ] ++
      read_args ++
      ["--dev", "/dev"] ++
      ["--proc", "/proc"]
  end

  defp append_net_flag(args, %{"net" => true}), do: args ++ ["--share-net"]
  defp append_net_flag(args, %{"net" => false}), do: args ++ ["--unshare-net"]

  # Bind the canonical workspace read-write ONLY when the mode's caps
  # include ":workspace". Otherwise the workspace stays read-only via
  # the `--ro-bind / /`, so writes to it fail at the kernel level.
  defp append_workspace_bind(args, %{"fs" => %{"write" => writes}}, workspace)
       when is_binary(workspace) do
    if ":workspace" in writes do
      ws = FSPath.canonical(workspace)
      args ++ ["--bind", ws, ws]
    else
      args
    end
  end

  defp append_workspace_bind(args, _caps, _workspace), do: args

  # Bind the remaining fs.write paths at their canonical paths.
  # `:workspace`, `/tmp`, and the workspace (raw or canonical) are
  # rejected because they are handled by dedicated bind steps.
  defp append_write_binds(args, %{"fs" => %{"write" => writes}}, workspace) do
    already_bound =
      [":workspace", "/tmp"] ++
        if(is_binary(workspace), do: [workspace, FSPath.canonical(workspace)], else: [])

    extras =
      writes
      |> Enum.reject(&(&1 in already_bound))
      |> Enum.map(&FSPath.canonical/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path -> ["--bind", path, path] end)

    args ++ extras
  end

  # Bind the runtime tmp_path (e.g. /tmp/nest-123/agent-456) at /tmp
  # inside the sandbox. This is what makes "/tmp" symbolic — every
  # agent gets its own scratch directory, but the path inside the
  # sandbox is always /tmp.
  defp append_tmp_bind(args, nil), do: args

  defp append_tmp_bind(args, tmp_path) do
    args ++ ["--bind", FSPath.canonical(tmp_path), "/tmp"]
  end

  defp append_chdir(args, chdir_path) do
    args ++ ["--chdir", chdir_path]
  end

  defp read_list(caps), do: get_in(caps, ["fs", "read"]) || []

  defp write_list(caps), do: get_in(caps, ["fs", "write"]) || []
end
