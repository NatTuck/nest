defmodule Nest.Sandbox do
  @moduledoc """
  The single, authoritative gatekeeper for all agent file access.

  Everything an agent reads, writes, stats, or executes goes through
  this module. It has three facets:

  ## The sandbox's filesystem view is bwrap's view

  There is **no host-side emulation** of `read`, `stat`, or `glob`: all three
  execute a command inside bwrap via `ShellCmd.execute_raw/5`, so their bytes
  and metadata come from exactly the mounts bwrap exposes and can never
  disagree with what a shell inside the sandbox sees. The only path mapping
  that remains is the scratch bind source and the reported sandbox spelling,
  both defined once in `Nest.Sandbox.Paths`.

  The agent-facing path domain is the *sandbox* domain: the space scratch dir
  is bound at `/tmp`, so an agent's own scratch directory is
  `/tmp/<agent-name>/...`. Every public executor accepts and returns paths in
  that domain only. The host scratch spelling
  (`/tmp/nest-<ospid>/space-<id>/<agent>/...`) is internal to this module and
  must never reach the LLM.

  ## bwrap argument builder

  `build/3`, `build/4`, and `build/5` translate caps into a bwrap command line.
  Paths are canonicalized (symlinks resolved) for bind *mounts* so a
  symlink-traversing workspace binds to its real target; `--chdir` stays on
  the user-provided path so the LLM and tools keep addressing files exactly as
  the user gave them.

  A workspace at or under `/tmp` is rejected when a scratch bind is present:
  the scratch dir is bound at `/tmp`, so it would shadow the workspace and
  every read/stat/glob would silently resolve against the wrong tree. A `nil`
  workspace means "no workspace": no workspace bind, and the sandbox chdirs to
  the scratch root (`/tmp`) when one is bound.

  ## Executors

  `read/4` runs `cat -- <path>` inside bwrap, `stat/5` runs
  `stat -L -c '%s|%Y|%f'`, and `glob/5` runs a bash glob loop. `write/5` and
  `run/5` go through `ShellCmd` too, so write/execute permissions are enforced
  by the mounts.

  On failure, `read/4` and `stat/5` classify bwrap's stderr (permission denied,
  missing path) into the same error atoms callers already handle.

  ## Caps shape

  Caps are a raw map matching the JSONB shape stored on `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{
          "read" => [String.t()],
          "write" => [String.t()]
        },
        "shell" => %{"background" => non_neg_integer()}
      }

  * `"net"` — when `true`, the sandbox shares the host's network namespace
    (`--share-net`); when `false`, network is unshared.
  * `"fs.read"` — must include `"/"` to run any command. `["/"]` produces
    `--ro-bind / /`.
  * `"fs.write"` — the explicit list of paths bound read-write. The
    `":workspace"` and `"/tmp"` entries are symbolic (resolved to the canonical
    workspace and the space's scratch dir); any other path is bound at its
    canonical path. Anything not in the write list stays read-only via
    `--ro-bind / /`.
  * `"shell.background"` (optional) — the per-agent ceiling on concurrent
    background shell jobs (default 1; 0 disables). Set by a project's `.nest`
    `[shell] background`. Enforced by `Nest.Sandbox.ShellJobs`, not by the
    mounts.

  ## Missing paths

  A non-existent workspace is rejected before bwrap runs (bwrap never creates
  it). A non-existent `fs.write` path fails at bwrap time as a missing source
  rather than being created: any operation that would fail on a missing
  directory fails, it is never auto-created.

  ## Device passthrough / HPU

  bwrap runs with `--unshare-all` and a fresh `--dev` devtmpfs by default. On a
  host with Habana Gaudi (HPU) devices, the sandbox instead binds the host's
  `/dev` with `--dev-bind` (a fresh devtmpfs has no accelerator nodes) and
  binds `Hardware.habana_log_dir/0` read-write (the driver logs there and the
  path is read-only under the root `--ro-bind / /`). Everything else about the
  sandbox is unchanged.
  """

  import Bitwise

  require Logger

  alias Nest.FSPath
  alias Nest.Hardware
  alias Nest.Sandbox.{Caps, Paths}
  alias Nest.Tools.{ShellCmd, ShellEscape}

  # A glob is a scatter target (e.g. `agents-batch`); an unbounded match count
  # would fork unbounded children, so we cap expansion and surface a
  # `:glob_too_broad` error so a caller can tell the model to narrow it.
  @glob_limit 1_000
  # Bash materialises the whole match list before the loop runs, so the match
  # limit does not bound the *work*. A timeout keeps a pathological pattern
  # (e.g. a huge single directory) from hanging the tool worker.
  @glob_timeout_ms 30_000

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
  @spec build_default(String.t(), String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def build_default(workspace_path, tmp_path) do
    build(default_caps(), workspace_path, tmp_path)
  end

  @doc """
  Build the bwrap argument list for the given caps, workspace, and tmp
  path. The workspace is bound at its canonical (symlink-resolved)
  path and `--chdir` targets `workspace_path` (the user-provided path).
  """
  @spec build(map(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path) do
    build(caps, workspace_path, tmp_path, workspace_path)
  end

  @doc """
  Build bwrap args, binding the workspace (canonicalized) while
  `--chdir`-ing to `chdir_path`. `chdir_path` lets callers keep the
  user-facing workspace path while the mount uses the canonical one.

  Detects the host's HPU devices via `Nest.Hardware`, ensuring the
  Habana log dir exists when we're on an HPU host, then delegates to
  `build/5`.
  """
  @spec build(map(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path, chdir_path) do
    hpu_device_paths = Hardware.hpu_device_paths()
    Hardware.ensure_habana_log_dir(hpu_device_paths, Hardware.habana_log_dir())
    build(caps, workspace_path, tmp_path, chdir_path, hpu_device_paths)
  end

  @doc """
  Build bwrap args with an explicit HPU device-path list.

  When `hpu_device_paths` is non-empty, the host's `/dev` is bound with
  `--dev-bind` (a fresh `--dev` devtmpfs has no accelerator nodes) and
  `Hardware.habana_log_dir/0` is bound read-write (the driver logs
  there, and it is read-only under the root `--ro-bind / /`). Otherwise
  the default fresh `--dev` devtmpfs is used. The argument is threaded
  explicitly so tests can exercise both branches without mutating the
  global `:hpu_device_paths` config. Unlike `build/4`, this arity does
  not ensure the log dir exists.
  """
  @spec build(map(), String.t() | nil, String.t() | nil, String.t() | nil, [String.t()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path, chdir_path, hpu_device_paths) do
    with :ok <- validate_caps(caps),
         :ok <- validate_workspace(workspace_path, tmp_path) do
      Nest.ProjectConfig.ensure_dirs(caps)

      args =
        base_args(caps, hpu_device_paths)
        |> append_net_flag(caps)
        |> append_workspace_bind(caps, workspace_path)
        |> append_write_binds(caps, workspace_path)
        |> append_tmp_bind(tmp_path)
        |> append_project_binds(caps)
        |> append_protected_binds(caps)
        |> append_chdir(chdir_path, tmp_path)

      {:ok, args}
    end
  end

  @doc """
  Validates a caps map. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_caps(map()) :: :ok | {:error, String.t()}
  defdelegate validate_caps(caps), to: Caps, as: :validate

  @doc """
  The canonical host paths the sandbox exposes read-only (from
  `caps.fs.read`).
  """
  @spec readable_roots(map()) :: [String.t()]
  def readable_roots(caps) do
    caps |> read_list() |> Enum.map(&FSPath.canonical/1) |> Enum.uniq()
  end

  @doc """
  Resolve a tool path against the workspace root (see `Nest.FSPath.resolve/2`).
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, workspace), do: FSPath.resolve(path, workspace)

  @doc """
  The path an agent's own scratch dir (`tmp_path`) appears at inside the
  sandbox: `/tmp/<agent-name>` (the space dir is bound at `/tmp`).

  This is the only spelling an agent should ever be told about or hand
  back; the host backing path is internal to this module.
  """
  @spec sandbox_tmp_path(String.t()) :: String.t()
  defdelegate sandbox_tmp_path(tmp_path), to: Paths

  # ---- Executors ----

  @doc """
  Read `path` (a sandbox-domain path) inside the bwrap sandbox and return
  its contents. The read is resolved by exactly the mounts bwrap builds,
  so the host spelling of the scratch dir is never involved.

  Returns `{:ok, content}`, `{:error, :read_permission_denied}`,
  `{:error, :enoent}`, or `{:error, reason}`. `workspace` and `tmp_path`
  are HOST paths used only to build the sandbox; they are never returned.
  """
  @spec read(String.t(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, binary()} | {:error, atom() | term()}
  def read(path, caps, workspace, tmp_path) do
    command = "cat -- " <> ShellEscape.escape(path)

    case ShellCmd.execute_raw(command, bind_workspace(workspace), tmp_path, caps) do
      {:ok, 0, stdout, _stderr} ->
        {:ok, stdout}

      {:ok, _exit_code, _stdout, stderr} ->
        reason = classify_read_failure(stderr)
        log_read_failure(path, reason, stderr)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stat `path` (a sandbox-domain path) inside the bwrap sandbox.

  Runs `stat -L -c '%s|%Y|%f'` through `ShellCmd.execute_raw/5` and returns a
  partial `%File.Stat{}`: `size`, `type`, and `mode` are populated; `mtime` is
  a POSIX integer when `opts` requests `time: :posix` and a
  `{{y, m, d}, {h, mi, s}}` tuple otherwise. The remaining `%File.Stat{}`
  fields are `nil` — no consumer reads them.

  Returns `{:ok, stat}`, `{:error, reason}`, or
  `{:error, :read_permission_denied}`.
  """
  @spec stat(String.t(), map(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, File.Stat.t()} | {:error, atom() | term()}
  def stat(path, caps, workspace, tmp_path, opts \\ []) do
    command = "stat -L -c '%s|%Y|%f' -- " <> ShellEscape.escape(path)

    case ShellCmd.execute_raw(command, bind_workspace(workspace), tmp_path, caps) do
      {:ok, 0, stdout, _stderr} ->
        parse_stat(stdout, opts)

      {:ok, _exit_code, _stdout, stderr} ->
        {:error, classify_read_failure(stderr)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Expand a glob `pattern` (a sandbox-domain path) to readable regular
  files by running a bash glob loop inside bwrap. Because the glob runs
  inside the sandbox, it sees exactly the mounts bwrap exposes — including
  the `/tmp` scratch bind and any project mounts — and returns the matches
  in the sandbox spelling (`/tmp/<agent>/...`). The host spelling never
  leaves this module.

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one non-`/`
  char), and `**` (any run of path segments when it occupies a full
  segment). A pattern ending in a full-segment `**` is refused
  (`{:error, :glob_terminal_double_star}`): bash would eagerly expand the
  whole subtree, and the file-only filter would then apply recursively
  rather than to the matched directories.

  `opts` accepts `limit:` (default `@glob_limit`), the max number of raw
  matches the pattern may produce before the call returns
  `{:error, :glob_too_broad}` (so a scatter caller can ask the model to
  narrow the pattern rather than fork an unbounded set). A resolve
  failure for a relative pattern with no workspace returns
  `{:error, reason}`.
  """
  @spec glob(String.t(), map(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, [String.t()]} | {:error, atom() | term()}
  def glob(pattern, caps, workspace, tmp_path, opts \\ [])
      when is_binary(pattern) and is_map(caps) do
    limit = Keyword.get(opts, :limit, @glob_limit)

    with {:ok, full} <- FSPath.resolve(pattern, workspace),
         :ok <- reject_terminal_double_star(full) do
      run_glob(full, caps, workspace, tmp_path, limit)
    end
  end

  @doc """
  Run `command` inside the bwrap sandbox. Authorizes nothing further
  itself — the mounts enforce filesystem rules. Delegates to
  `ShellCmd.execute/5`.
  """
  @spec run(String.t(), String.t() | nil, String.t() | nil, map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(command, workspace, tmp_path, caps, opts \\ []) do
    ShellCmd.execute(command, bind_workspace(workspace), tmp_path, caps, opts)
  end

  @doc """
  Write `content` to `path` inside the bwrap sandbox. Write
  permissions are enforced by the bind mounts, so a write outside the
  permitted paths fails at the kernel level (read-only file system)
  rather than being pre-authorized here. Returns `{:ok, output}` or
  `{:error, reason}`.
  """
  @spec write(String.t(), binary(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def write(path, content, caps, workspace, tmp_path) do
    ShellCmd.execute(
      "cat > #{ShellEscape.escape(path)}",
      bind_workspace(workspace),
      tmp_path,
      caps,
      stdin: content
    )
  end

  # ---- glob ----

  defp run_glob(full, caps, workspace, tmp_path, limit) do
    script = glob_script(shell_glob(full), limit)

    case ShellCmd.execute_raw(script, bind_workspace(workspace), tmp_path, caps,
           timeout: @glob_timeout_ms
         ) do
      {:ok, 0, stdout, _stderr} ->
        {:ok, stdout |> split_nul() |> Enum.sort() |> Enum.uniq()}

      {:ok, 3, _stdout, _stderr} ->
        {:error, :glob_too_broad}

      {:ok, _exit_code, _stdout, stderr} ->
        {:error, classify_read_failure(stderr)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `full` is a resolved absolute pattern in the sandbox spelling. Bash
  # resolves symlinks and the `/tmp` bind exactly as a shell inside the
  # sandbox would, which is the entire point of running glob in bwrap.
  #
  # Nest stages this very script into the agent's scratch dir under the
  # reserved `.nest-cmd-` prefix (visible inside at `/tmp/<agent>/...`), so the
  # loop skips that prefix: it is an internal transcript, not a sandbox file
  # the agent created.
  defp glob_script(escaped_pattern, limit) do
    """
    shopt -s nullglob globstar dotglob
    n=0
    for p in #{escaped_pattern}; do
      case ${p##*/} in .nest-cmd-*) continue;; esac
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
  # shell performs pathname expansion on the glob metacharacters while
  # treating `[`, `]`, `{`, `}`, `\`, `~`, spaces, and quotes literally
  # (matching today's `*`/`?`-only semantics).
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

  # ---- stat ----

  defp parse_stat(stdout, opts) do
    case stdout |> String.trim() |> String.split("|") do
      [size, mtime, mode] ->
        mode = String.to_integer(mode, 16)

        {:ok,
         %File.Stat{
           size: String.to_integer(size),
           mtime: format_mtime(String.to_integer(mtime), opts),
           mode: mode,
           type: type_from_mode(mode)
         }}

      _ ->
        {:error, :read_failed}
    end
  end

  defp format_mtime(seconds, opts) do
    if Keyword.get(opts, :time) == :posix do
      seconds
    else
      seconds
      |> Kernel.+(62_167_219_200)
      |> :calendar.gregorian_seconds_to_datetime()
      |> :calendar.universal_time_to_local_time()
    end
  end

  defp type_from_mode(mode) do
    case band(mode, 0xF000) do
      0x8000 -> :regular
      0x4000 -> :directory
      0xA000 -> :symlink
      0x2000 -> :device
      _ -> :other
    end
  end

  # ---- failure classification ----

  # A failed read/stat is classified from bwrap's stderr rather than by
  # inspecting the host: the host's view is not the sandbox's view (a masked
  # `.nest` is a char device inside but a plain file on the host).
  defp classify_read_failure(stderr) do
    cond do
      String.contains?(stderr, "Permission denied") -> :read_permission_denied
      String.contains?(stderr, "No such file or directory") -> :enoent
      String.contains?(stderr, "Not a directory") -> :enoent
      true -> :read_failed
    end
  end

  # A missing file is an ordinary tool outcome; only a genuinely unexpected
  # failure (`:read_failed`, e.g. a bwrap setup problem) is logged so a failed
  # read is never silent for the operator.
  defp log_read_failure(path, :read_failed, stderr) do
    Logger.warning("Nest.Sandbox.read: failed to read #{path}: #{inspect(stderr)}")
  end

  defp log_read_failure(_path, _reason, _stderr), do: :ok

  # ---- path helpers ----

  # A workspace that isn't a directory can't be bound; dropping it here keeps
  # `ShellCmd` from raising "Workspace directory does not exist" for callers
  # that pass a stale/non-existent workspace. The workspace is only used to
  # build the sandbox and is never returned.
  defp bind_workspace(workspace) do
    if is_binary(workspace) and File.dir?(workspace), do: workspace, else: nil
  end

  # ---- Internal arg-builder helpers ----

  # A workspace at or under the scratch bind's mount point (`/tmp`) would be
  # shadowed by the scratch bind, making every sandboxed operation resolve
  # against the wrong tree. A `nil` tmp_path means no scratch bind, so the
  # host `/tmp` is the real one and a workspace under it is fine.
  defp validate_workspace(nil, _tmp_path), do: :ok
  defp validate_workspace(_workspace, nil), do: :ok

  defp validate_workspace(workspace, _tmp_path) do
    if FSPath.under?(Paths.sandbox_root(), FSPath.canonical(workspace)) do
      {:error,
       "workspace must not be at or under #{Paths.sandbox_root()}: " <>
         "the sandbox scratch dir is bound there and would shadow it"}
    else
      :ok
    end
  end

  defp base_args(caps, hpu_device_paths) do
    read_args =
      caps
      |> readable_roots()
      |> Enum.flat_map(fn root -> ["--ro-bind", root, root] end)

    hpu_args = hpu_args(hpu_device_paths)

    # Read-only bind of the readable roots. Must come BEFORE
    # --dev/--proc so the devtmpfs overlays it and /proc/self stays
    # writable inside the sandbox.
    # Fresh devtmpfs over the read-only bind. Makes /dev/null,
    # /dev/zero, etc. writable for shell redirects. On an HPU host the
    # host's /dev is bound instead so accelerator nodes are present.
    # Mount the host's procfs after the read-only root bind so that
    # /proc/self/<pid>/... files stay writable inside the sandbox.
    [
      # Unshare everything by default; re-share net below if requested.
      "--unshare-all",
      "--die-with-parent",
      "--new-session"
    ] ++
      read_args ++
      hpu_args ++
      ["--proc", "/proc"]
  end

  # HPU hosts get the host's device nodes and a writable Habana log dir.
  # The log dir must be bound after the `--ro-bind / /` (which mounts it
  # read-only); `--dev-bind` is required because `--ro-bind` mounts with
  # nodev, making device nodes under the bound root unusable. `build/4`
  # ensures the log dir exists before we get here.
  defp hpu_args([]), do: ["--dev", "/dev"]

  defp hpu_args(_hpu_device_paths) do
    log_dir = Hardware.habana_log_dir()
    ["--bind", log_dir, log_dir, "--dev-bind", "/dev", "/dev"]
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

  # Bind each project mount at its declared path.
  defp append_project_binds(args, caps) do
    binds =
      caps
      |> project_list()
      |> Enum.filter(&is_binary(&1["source"]))
      |> Enum.flat_map(fn %{"dest" => dest, "source" => source} ->
        ["--bind", source, dest]
      end)

    args ++ binds
  end

  # Force the `.nest` file read-only AFTER the workspace bind so the
  # overlay wins. When `.nest` is absent the source is `/dev/null`, so
  # the path is a read-only empty file an agent can't replace.
  defp append_protected_binds(args, caps) do
    binds =
      caps
      |> protected_list()
      |> Enum.flat_map(fn %{"path" => path, "source" => source} ->
        ["--ro-bind", source, path]
      end)

    args ++ binds
  end

  # Bind the remaining fs.write paths at their canonical paths.
  defp append_write_binds(args, %{"fs" => %{"write" => writes}} = caps, workspace) do
    bound = already_bound(caps, workspace)

    extras =
      writes
      |> Enum.reject(&(&1 in bound))
      |> Enum.map(&FSPath.canonical/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path -> ["--bind", path, path] end)

    args ++ extras
  end

  # Paths already covered by a dedicated bind step.
  defp already_bound(caps, workspace) do
    [":workspace", "/tmp"] ++
      if(is_binary(workspace), do: [workspace, FSPath.canonical(workspace)], else: []) ++
      Enum.map(project_list(caps), & &1["dest"]) ++
      Enum.map(protected_list(caps), & &1["path"])
  end

  # Bind the *space* scratch directory at /tmp inside the sandbox. The
  # agent's own scratch dir is `<space_dir>/<agent-name>`, so the space
  # dir (its parent) is what gets bound. This is what makes "/tmp"
  # symbolic AND shared: every agent in a space sees the same /tmp, so a
  # file path handed from one agent to a sibling resolves for the
  # recipient. The agent's own dir appears at `/tmp/<agent-name>` inside.
  #
  # HOST PATH: `Paths.scratch_root/1` yields the host bind source. It must not
  # escape this module or be named to the agent (see the moduledoc).
  defp append_tmp_bind(args, nil), do: args

  defp append_tmp_bind(args, tmp_path) do
    args ++ ["--bind", Paths.scratch_root(tmp_path), Paths.sandbox_root()]
  end

  # `nil` chdir means "no workspace": land in the scratch root when one is
  # bound (the effective cwd before the workspace was made explicit), else
  # the read-only root.
  defp append_chdir(args, nil, nil), do: args ++ ["--chdir", "/"]
  defp append_chdir(args, nil, _tmp_path), do: args ++ ["--chdir", Paths.sandbox_root()]
  defp append_chdir(args, chdir_path, _tmp_path), do: args ++ ["--chdir", chdir_path]

  defp read_list(caps), do: get_in(caps, ["fs", "read"]) || []

  defp project_list(caps), do: get_in(caps, ["fs", "project"]) || []

  defp protected_list(caps), do: get_in(caps, ["fs", "protected"]) || []
end
