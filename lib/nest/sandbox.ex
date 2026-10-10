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
  mounts from them, and the stat/glob host fast-path authorizes from
  them, so the fast-path can never permit something the mounts deny
  (and vice-versa).

  ## bwrap argument builder

  `build/3` and `build/4` translate caps into a bwrap command line.
  Paths are canonicalized (symlinks resolved) for bind *mounts* so a
  symlink-traversing workspace binds to its real target; `--chdir`
  stays on the user-provided path so the LLM and tools keep addressing
  files exactly as the user gave them.

  ## Executors

  The agent-facing path domain is the *sandbox* domain: the space
  scratch dir is bound at `/tmp`, so an agent's own scratch directory
  is `/tmp/<agent-name>/...`. Every public executor accepts and returns
  paths in that domain only.

  `read/4` runs `cat -- <path>` inside bwrap via
  `ShellCmd.execute_raw/5`, so the bytes come from exactly the mounts
  bwrap exposes and the host spelling of the scratch dir is never
  computed or named by a caller.

  `stat/4` and `glob/5` keep a host fast-path, but it is a private
  implementation detail of this module: `Nest.Sandbox.Paths.to_host/3`
  maps a sandbox path onto its host backing path using the *same*
  `Nest.Sandbox.Paths.scratch_root/1` that `append_tmp_bind/2` uses for
  the `/tmp` mount, and `to_sandbox/2` maps results back. Because the
  mount and the translation derive from one definition, a bind-layout
  change cannot silently make a stat/glob read the wrong file.

  **Host paths must never escape this module.** The host scratch
  spelling (`/tmp/nest-<ospid>/space-<id>/<agent>/...`) is an internal
  detail; the LLM must only ever see sandbox paths (`/tmp/<agent>/...`).
  Every point where a host path is used carries a comment restating
  this rule.

  `write/5` and `run/5` go through bwrap (`ShellCmd`), so
  write/execute permissions are enforced by the mounts.

  ## Caps shape

  Caps are a raw map matching the JSONB shape stored on
  `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{
          "read" => [String.t()],
          "write" => [String.t()]
        },
        "shell" => %{"background" => non_neg_integer()}
      }

  * `"net"` — when `true`, the sandbox shares the host's network
    namespace (`--share-net`); when `false`, network is unshared.
  * `"fs.read"` — must include `"/"` to run any command. `["/"]`
    produces `--ro-bind / /`.
  * `"fs.write"` — the explicit list of paths bound read-write. The
    `":workspace"` and `"/tmp"` entries are symbolic (resolved to the
    canonical workspace and the space's scratch dir); any other path
    is bound at its canonical path. Anything not in the write list
    stays read-only via `--ro-bind / /`.
  * `"shell.background"` (optional) — the per-agent ceiling on
    concurrent background shell jobs (default 1; 0 disables). Set by a
    project's `.nest` `[shell] background`. Enforced by
    `Nest.Sandbox.ShellJobs`, not by the mounts.

  ## Missing paths

  A non-existent workspace is rejected before bwrap runs (bwrap never
  creates it). A non-existent `fs.write` path fails at bwrap time as a
  missing source rather than being created: any operation that would
  fail on a missing directory fails, it is never auto-created.

  ## Device passthrough / HPU

  bwrap runs with `--unshare-all` and a fresh `--dev` devtmpfs by
  default. On a host with Habana Gaudi (HPU) devices, the sandbox
  instead binds the host's `/dev` with `--dev-bind` (a fresh devtmpfs
  has no accelerator nodes) and binds `Hardware.habana_log_dir/0`
  read-write (the driver logs there and the path is read-only under the
  root `--ro-bind / /`). Everything else about the sandbox is unchanged.
  """

  alias Nest.FSPath
  alias Nest.Hardware
  alias Nest.Sandbox.{Caps, Glob, Paths}
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

  Detects the host's HPU devices via `Nest.Hardware`, ensuring the
  Habana log dir exists when we're on an HPU host, then delegates to
  `build/5`.
  """
  @spec build(map(), String.t(), String.t() | nil, String.t()) ::
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
  @spec build(map(), String.t(), String.t() | nil, String.t(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, workspace_path, tmp_path, chdir_path, hpu_device_paths) do
    with :ok <- validate_caps(caps) do
      Nest.ProjectConfig.ensure_dirs(caps)

      args =
        base_args(caps, hpu_device_paths)
        |> append_net_flag(caps)
        |> append_workspace_bind(caps, workspace_path)
        |> append_write_binds(caps, workspace_path)
        |> append_tmp_bind(tmp_path)
        |> append_project_binds(caps)
        |> append_protected_binds(caps)
        |> append_chdir(chdir_path)

      {:ok, args}
    end
  end

  @doc """
  Validates a caps map. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_caps(map()) :: :ok | {:error, String.t()}
  defdelegate validate_caps(caps), to: Caps, as: :validate

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
  the sandbox, not at a user-facing host path: the space's scratch
  directory is bound there by `append_tmp_bind/2` (derived from the
  agent's `tmp_path`, not from caps), so it is not a path a caller
  addresses directly.
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

    project = caps |> project_list() |> Enum.map(& &1["dest"])
    protected = caps |> protected_list() |> Enum.map(& &1["path"])

    (workspace_root ++ extras ++ project)
    |> Enum.reject(&(&1 in protected))
    |> Enum.uniq()
  end

  @doc """
  True when `path` is readable under `caps` — i.e. its canonical path
  lies beneath a readable root. Produces the same result bwrap's
  read-only binds would.
  """
  @spec read_allowed?(String.t(), map()) :: boolean()
  def read_allowed?(path, caps) do
    canonical = FSPath.canonical(path)

    roots =
      readable_roots(caps) ++
        Enum.map(project_list(caps), & &1["dest"]) ++
        Enum.map(protected_list(caps), & &1["path"])

    Enum.any?(roots, &FSPath.under?(&1, canonical))
  end

  @doc """
  True when `path` is writable under `caps` — i.e. its canonical path
  lies beneath a writable root (canonical workspace or an extra write
  path). Produces the same result bwrap's read-write binds would.
  """
  @spec write_allowed?(String.t(), map(), String.t() | nil) :: boolean()
  def write_allowed?(path, caps, workspace) do
    canonical = FSPath.canonical(path)

    not protected?(canonical, caps) and
      Enum.any?(writable_roots(caps, workspace), &FSPath.under?(&1, canonical))
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
  def sandbox_tmp_path(tmp_path), do: Path.join("/tmp", Path.basename(tmp_path))

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

    # HOST PATH: `workspace` is the optional host workspace to bind into the
    # sandbox. Drop it when it isn't a directory so a missing workspace can't
    # raise here; it is only used to build the sandbox and is never returned.
    workspace = if is_binary(workspace) and File.dir?(workspace), do: workspace, else: nil

    case ShellCmd.execute_raw(command, workspace, tmp_path, caps) do
      {:ok, 0, stdout, _stderr} ->
        {:ok, stdout}

      {:ok, _exit_code, _stdout, _stderr} ->
        {:error, classify_read_failure(path, caps, workspace, tmp_path)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stat `path` (a sandbox-domain path) after authorizing it via
  `read_allowed?/2`. Keeps a host fast-path, but the host path is computed
  by `Nest.Sandbox.Paths.to_host/3` from the same bind definition as the
  `/tmp` mount and never leaves this module. `opts` are passed to
  `File.stat/2` (e.g. `time: :posix`). Returns `{:ok, stat}`,
  `{:error, reason}`, or `{:error, :read_permission_denied}`.
  """
  @spec stat(String.t(), map(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, File.Stat.t()} | {:error, atom() | term()}
  def stat(path, caps, workspace, tmp_path, opts \\ []) do
    # HOST PATH: computed here, used only for the `File.stat/2` below, and
    # never returned. The LLM must only ever see the sandbox spelling.
    host = Paths.to_host(path, workspace, tmp_path)

    if read_permitted?(host, caps, tmp_path) do
      File.stat(Nest.ProjectConfig.read_source(host, caps), opts)
    else
      {:error, :read_permission_denied}
    end
  end

  # True when a HOST path is readable under the caps, or lives in the agent's
  # scratch bind root (which bwrap always exposes read-write, regardless of
  # the mode's read list). The host path stays internal to this module.
  defp read_permitted?(host, caps, tmp_path) do
    read_allowed?(host, caps) or
      (is_binary(tmp_path) and FSPath.under?(Paths.scratch_root(tmp_path), host))
  end

  # Classify a failed sandbox read for the caller's error message. `path` is
  # the sandbox-domain path; `Paths.to_host/3` yields the HOST backing path,
  # which is kept internal and never returned.
  defp classify_read_failure(path, caps, workspace, tmp_path) do
    host = Paths.to_host(path, workspace, tmp_path)

    cond do
      not read_permitted?(host, caps, tmp_path) -> :read_permission_denied
      not File.exists?(host) -> :enoent
      true -> :read_failed
    end
  end

  # Hard ceiling on how many files `glob/5` will expand. A glob is a
  # scatter target (e.g. `agents-batch`); an unbounded match count would
  # fork unbounded children, so we cap expansion and surface a
  # `:glob_too_broad` error so a caller can tell the model to narrow it.
  @glob_limit 1_000

  @doc """
  Expand a glob `pattern` (a sandbox-domain path) to readable regular
  files, honoring the same read caps as `read/4`. The pattern is resolved
  against `workspace` (an absolute pattern is used as-is), expanded via a
  host fast-path, filtered to regular files whose canonical path is
  readable under `caps`, then returned sorted and deduplicated **in the
  sandbox spelling** (`/tmp/<agent>/...`). The host spelling never leaves
  this module.

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one
  non-`/` char), and `**` (any run of path segments, including none —
  matched across directory boundaries when it occupies a full segment).

  `opts` accepts `limit:` (default `@glob_limit`), the max number of
  files the pattern may match before the call returns
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

    with {:ok, full} <- FSPath.resolve(pattern, workspace) do
      # `Glob.walk/3` `throw`s `:glob_too_broad` when the match count
      # exceeds the limit (unwinding the recursion early). The per-segment
      # matcher is total (it never raises on a malformed pattern), so this
      # `:error` arm is a defensive backstop: translate any unexpected error
      # into a `:invalid_glob` result rather than crashing the agent's tool
      # worker. `e` may be a raw (non-exception) term, so `inspect` it.
      try do
        {:ok, collect_matches(full, caps, workspace, tmp_path, limit)}
      catch
        :throw, :glob_too_broad -> {:error, :glob_too_broad}
        :error, e -> {:error, {:invalid_glob, inspect(e)}}
      end
    end
  end

  # Expand a resolved absolute glob `full` (sandbox spelling) to readable
  # regular files in the sandbox spelling: translate the literal base to its
  # HOST backing path, walk the host, keep only readable regular files, then
  # translate every match back. `Glob.walk/3` may `throw` `:glob_too_broad`
  # from here (propagated to the caller's `catch`).
  #
  # HOST PATH: the translated base and walked matches are host spellings and
  # must not escape this module (see the moduledoc).
  defp collect_matches(full, caps, workspace, tmp_path, limit) do
    {base, rest} = Glob.split(full)

    base
    |> Paths.to_host(workspace, tmp_path)
    |> FSPath.canonical()
    |> Glob.walk(rest, limit)
    |> Enum.filter(fn host -> File.regular?(host) and read_permitted?(host, caps, tmp_path) end)
    |> Enum.map(&Paths.to_sandbox(&1, tmp_path))
    |> Enum.sort()
    |> Enum.uniq()
  end

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
  # HOST PATH: `Paths.scratch_root/1` yields the host bind source — the same
  # definition the stat/glob translation uses. It must not escape this
  # module or be named to the agent (see the moduledoc).
  defp append_tmp_bind(args, nil), do: args

  defp append_tmp_bind(args, tmp_path) do
    args ++ ["--bind", Paths.scratch_root(tmp_path), "/tmp"]
  end

  defp append_chdir(args, chdir_path) do
    args ++ ["--chdir", chdir_path]
  end

  defp read_list(caps), do: get_in(caps, ["fs", "read"]) || []

  defp write_list(caps), do: get_in(caps, ["fs", "write"]) || []

  defp project_list(caps), do: get_in(caps, ["fs", "project"]) || []

  defp protected_list(caps), do: get_in(caps, ["fs", "protected"]) || []

  defp protected?(canonical, caps) do
    Enum.any?(protected_list(caps), fn p -> FSPath.under?(p["path"], canonical) end)
  end
end
