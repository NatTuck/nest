defmodule Nest.Sandbox do
  @moduledoc """
  The single, authoritative gatekeeper for all agent file access.

  Everything an agent reads, writes, stats, or executes goes through
  this module. It has three facets:

  ## The sandbox's filesystem view is the backend's view

  There is **no host-side emulation** of `read`, `stat`, or `glob`: all three
  execute a command inside the sandbox via `ShellCmd.execute_raw/4`, so their
  bytes and metadata come from exactly what the backend exposes and can never
  disagree with what a shell inside it sees. Which backend that is — `bwrap`,
  `docker` or the bare command — is a space property, carried on the `Mounts`
  value and dispatched by `Nest.Sandbox.Backend`. The only path mapping that
  remains is the scratch bind source and the reported sandbox spelling, both
  defined once in `Nest.Sandbox.Paths`.

  An agent names exactly one domain of paths, and it is the same domain on
  every backend: the *sandbox* domain. The space scratch dir is bound at
  `/tmp`, so an agent's own scratch directory is `/tmp/<agent-name>/...`; the
  workspace is bound at its own path, so the string an agent uses for a
  workspace file is the string the workspace already has. Every public executor
  accepts and returns paths in that domain only.

  The value that travels — the backend plus the two directories the sandbox
  binds — is one `Nest.Sandbox.Mounts`, held by the agent and passed to every
  executor. This module is what turns that value into binds (for the bwrap
  backend) and nothing outside it needs a directory in order to name a path an
  agent uses: a caller that wants a real directory (to stage a script into, to
  write an offload into) reads it from the value, but the path it hands back to
  the agent is always the agent's own spelling.

  ## Backends

  `Nest.Sandbox.Backend` is the dispatch, and each backend is a module under it.
  The three differ in *what* they enforce — `bwrap` binds and unshares,
  `docker` runs bwrap inside a container whose root filesystem is the derived
  image (so `caps.fs.read`'s readable roots are not what it binds: the image is
  the read set, and the same bind list is applied over the image instead of over
  the host), and `none` runs the bare command on the host and enforces nothing.
  The bind list itself is shared: `Nest.Sandbox.Binds` derives it once and both
  binding backends render it. Everything below that names bwrap — the argument
  builder, the caps section's bind rules, the device passthrough — is
  `Nest.Sandbox.Backend.Bwrap`'s, and the full comparison is in
  `notes/sandbox-backends.md`.

  ## bwrap argument builder

  `build/2`, `build/3`, and `build/4` translate caps plus a `Mounts` value into
  a bwrap command line — they are the `Nest.Sandbox.Backend.Bwrap`
  implementation's builder, reached through `Nest.Sandbox.Backend`, not a
  general entry point. Paths are canonicalized (symlinks resolved) for bind
  *mounts* so a symlink-traversing workspace binds to its real target;
  `--chdir` stays on the workspace path the caller gave, so the LLM and tools
  keep addressing files exactly as the user gave them.

  A workspace at or under `/tmp` is rejected **unconditionally**: the space
  scratch dir is bound at `/tmp` by every backend that binds anything, so it
  would shadow the workspace and every read/stat/glob would silently resolve
  against the wrong tree. A missing workspace is rejected too (a sandbox never
  creates one). A `nil` workspace means "no workspace": no workspace bind, and
  the sandbox chdirs to the scratch root (`/tmp`) when one is bound.

  ## Executors

  `read/3` runs `cat -- <path>` inside the sandbox, `stat/4` runs
  `stat -L -c '%s|%Y|%f'`, and `glob/4` runs a bash glob loop. `write/4` and
  `run/4` go through `ShellCmd` too, so write/execute permissions are enforced
  by the mounts — and on a backend that binds nothing, they are enforced by
  nothing at all (see `Nest.Sandbox.Backend.None`).

  On failure, `read/3`, `stat/4`, and `glob/4` classify the command's stderr
  through the backend into an error atom: sandbox setup failures
  (`:sandbox_setup_failed`), timeouts (`:read_timeout`), cancellation
  (`:read_cancelled`), permission denials (`:read_permission_denied`), missing
  paths (`:enoent`), and directories passed
  to a file read (`:eisdir`). Unexpected failures are logged; ordinary tool
  outcomes are not.

  ## Caps shape

  Caps describe what the *mode* allows; which of it a backend can enforce is the
  backend's business (see `Nest.Sandbox.Backend`). Caps are a raw map matching
  the JSONB shape stored on `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{
          "read" => [String.t()],
          "write" => [String.t()]
        },
        "shell" => %{"background" => non_neg_integer()}
      }

  * `"net"` — when `true`, the sandbox shares the host's network namespace
    (`--share-net`); when `false`, network is unshared. This one is the
    **space's** value, not the mode's: `spaces.network_access` is resolved once at
    agent start and injected here by `with_network_access/2`, so a mode's own
    `"net"` is dead data. See `Nest.Spaces.Space`.
  * `"fs.read"` — must include `"/"` to run any command. `["/"]` produces
    `--ro-bind / /`.
  * `"fs.write"` — the explicit list of paths bound read-write. The
    `":workspace"` and `"/tmp"` entries are symbolic (resolved to the canonical
    workspace and the space's scratch dir); any other path is bound at its
    canonical path. Anything not in the write list stays read-only via
    `--ro-bind / /`. The symbolic `"/tmp"` entry is what makes the agent's
    scratch dir writable; with no scratch dir to honor it, `/tmp` stays the
    read-only host `/tmp` and a write there fails at the kernel like any other
    write outside the write list.
  * `"shell.background"` (optional) — the per-agent ceiling on concurrent
    background shell jobs (default 1; 0 disables). Set by a project's `.nest`
    `[shell] background`. Enforced by `Nest.Sandbox.ShellJobs`, not by the
    mounts.

  ## Missing paths

  A non-existent workspace is rejected before the sandbox starts (nothing
  creates one). A non-existent `fs.write` path fails as a missing bind source
  rather than being created: any operation that would fail on a missing
  directory fails, it is never auto-created.

  ## Device passthrough / HPU (the bwrap backend)

  bwrap runs with `--unshare-all` and a fresh `--dev` devtmpfs by default. On a
  host with Habana Gaudi (HPU) devices, the sandbox instead binds the host's
  `/dev` with `--dev-bind` (a fresh devtmpfs has no accelerator nodes) and
  binds `Hardware.habana_log_dir/0` read-write (the driver logs there and the
  path is read-only under the root `--ro-bind / /`). Everything else about the
  sandbox is unchanged. This whole section is `Nest.Sandbox.Backend.Bwrap`'s
  business: it is what `build/2,3,4` below construct.
  """

  import Bitwise

  alias Nest.FSPath
  alias Nest.Hardware
  alias Nest.Sandbox.{Backend, Binds, Caps, Failure, Glob, Mounts, Paths, StatBatch}
  alias Nest.Tools.{ShellCmd, ShellEscape}

  @doc """
  The default "build" profile (full host read, workspace + /tmp
  writable, no network). Used by callers that haven't been migrated to
  pass real caps (and as the fallback in `ShellCmd.execute/4`).
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
  @spec build_default(Mounts.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def build_default(mounts) do
    build(default_caps(), mounts)
  end

  @doc """
  Build the bwrap argument list for the given caps and mounts. The workspace
  is bound at its canonical (symlink-resolved) path and `--chdir` targets the
  workspace path the caller gave.
  """
  @spec build(map(), Mounts.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, mounts) do
    build(caps, mounts, Mounts.workspace(mounts))
  end

  @doc """
  Build bwrap args, binding the workspace (canonicalized) while
  `--chdir`-ing to `chdir_path`. `chdir_path` lets callers keep the
  user-facing workspace path while the mount uses the canonical one.

  Detects the host's HPU devices via `Nest.Hardware`, ensuring the
  Habana log dir exists when we're on an HPU host, then delegates to
  `build/4`.
  """
  @spec build(map(), Mounts.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, mounts, chdir_path) do
    hpu_device_paths = Hardware.hpu_device_paths()
    Hardware.ensure_habana_log_dir(hpu_device_paths, Hardware.habana_log_dir())
    build(caps, mounts, chdir_path, hpu_device_paths)
  end

  @doc """
  Build bwrap args with an explicit HPU device-path list.

  When `hpu_device_paths` is non-empty, the host's `/dev` is bound with
  `--dev-bind` (a fresh `--dev` devtmpfs has no accelerator nodes) and
  `Hardware.habana_log_dir/0` is bound read-write (the driver logs
  there, and it is read-only under the root `--ro-bind / /`). Otherwise
  the default fresh `--dev` devtmpfs is used. The argument is threaded
  explicitly so tests can exercise both branches without mutating the
  global `:hpu_device_paths` config. Unlike `build/3`, this arity does
  not ensure the log dir exists.
  """
  @spec build(map(), Mounts.t(), String.t() | nil, [String.t()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def build(caps, mounts, chdir_path, hpu_device_paths) do
    workspace = Mounts.workspace(mounts)

    with :ok <- validate_caps(caps),
         :ok <- validate_workspace(workspace) do
      Nest.ProjectConfig.ensure_dirs(caps)

      args =
        base_args(caps, hpu_device_paths)
        |> append_net_flag(caps)
        |> append_binds(caps, mounts)
        |> append_chdir(chdir_path, mounts)

      {:ok, args}
    end
  end

  @doc """
  Put the space's network access into `caps` as `"net"`.

  The network is a *space* property (`spaces.network_access`), not a vocation
  mode's, so this is where the mode's own `"net"` is overridden — and it is the
  one place, because every caps resolution ends in
  `Nest.ProjectConfig.resolve_caps/2`, which calls this. Nothing downstream
  changes: `Nest.Sandbox.build/2` and both backends keep reading `caps["net"]`.

  The value travels on the `Mounts` value (resolved once at agent start, like the
  backend), so no caps resolution reads the DB. A `Mounts` value that names no
  space carries `false`, which is `default_caps/0`'s value: an agent with no
  space behind it must not gain the network.
  """
  @spec with_network_access(map(), Mounts.t()) :: map()
  def with_network_access(caps, %Mounts{} = mounts) do
    Map.put(caps, "net", Mounts.network_access(mounts))
  end

  @doc """
  Validates a caps map. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_caps(map()) :: :ok | {:error, String.t()}
  defdelegate validate_caps(caps), to: Caps, as: :validate

  @doc """
  The canonical paths the sandbox exposes read-only (from `caps.fs.read`).
  """
  @spec readable_roots(map()) :: [String.t()]
  def readable_roots(caps) do
    caps |> read_list() |> Enum.map(&FSPath.canonical/1) |> Enum.uniq()
  end

  @doc """
  Resolve a tool path against the workspace root (see `Nest.Sandbox.Mounts.resolve/2`).
  """
  @spec resolve(String.t(), Mounts.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, mounts), do: Mounts.resolve(path, mounts)

  @doc """
  The path an agent's own scratch dir (`tmp_path`) appears at inside the
  sandbox: `/tmp/<agent-name>` (the space dir is bound at `/tmp`).

  This is the only spelling an agent is ever told about or hands back; the
  directory it is derived from is the caller's, and is never given to the
  agent.
  """
  @spec sandbox_tmp_path(String.t()) :: String.t()
  defdelegate sandbox_tmp_path(tmp_path), to: Paths

  @doc """
  The directory bound at `/tmp` inside the sandbox: `/tmp`.

  The sandbox spelling of the scratch root. The directory bound *at* it is
  per-agent (see `sandbox_tmp_path/1`).
  """
  @spec sandbox_root() :: String.t()
  defdelegate sandbox_root(), to: Paths

  @doc """
  The sandbox spelling of an agent's own scratch directory, derived from the
  agent's name alone: `/tmp/<agent-name>`.

  It takes a name and returns a spelling, so no directory is involved — the
  contrast with `sandbox_tmp_path/1`, which needs the agent's scratch
  directory. This is the only scratch spelling an agent is ever told about.
  """
  @spec scratch_dir(String.t()) :: String.t()
  defdelegate scratch_dir(name), to: Paths

  # ---- Executors ----

  @doc """
  Read `path` (a sandbox-domain path) inside the sandbox and return
  its contents. The read is resolved by exactly the mounts the backend builds.

  Returns `{:ok, content}`, `{:error, :read_permission_denied}`,
  `{:error, :enoent}`, or `{:error, reason}`.
  """
  @spec read(String.t(), map(), Mounts.t()) :: {:ok, binary()} | {:error, atom() | term()}
  def read(path, caps, mounts) do
    command = "LC_ALL=C cat -- " <> ShellEscape.escape(path)

    case ShellCmd.execute_raw(command, mounts, caps) do
      {:ok, 0, stdout, _stderr} ->
        {:ok, stdout}

      {:ok, _exit_code, _stdout, stderr} ->
        reason = Backend.classify(mounts, stderr)
        Failure.log(:read, path, reason, stderr)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stat `path` (a sandbox-domain path) inside the sandbox.

  Runs `stat -L -c '%s|%Y|%f'` through `ShellCmd.execute_raw/4` and returns a
  partial `%File.Stat{}`: `size`, `type`, and `mode` are populated; `mtime` is
  a POSIX integer when `opts` requests `time: :posix` and a
  `{{y, m, d}, {h, mi, s}}` tuple otherwise. The remaining `%File.Stat{}`
  fields are `nil` — no consumer reads them.

  Returns `{:ok, stat}`, `{:error, reason}`, or
  `{:error, :read_permission_denied}`.
  """
  @spec stat(String.t(), map(), Mounts.t(), keyword()) ::
          {:ok, File.Stat.t()} | {:error, atom() | term()}
  def stat(path, caps, mounts, opts \\ []) do
    command = "LC_ALL=C stat -L -c '%s|%Y|%f' -- " <> ShellEscape.escape(path)

    case ShellCmd.execute_raw(command, mounts, caps) do
      {:ok, 0, stdout, _stderr} ->
        parse_stat(stdout, opts)

      {:ok, _exit_code, _stdout, stderr} ->
        reason = Backend.classify(mounts, stderr)
        Failure.log(:stat, path, reason, stderr)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The sizes of many paths in as few sandbox spawns as possible (issue #48).

  `stat/3` is one sandbox spawn per path; the BatchSizer preflight needs only a
  size per `file-read` target, so this runs one `stat` invocation per chunk of
  paths instead of one per path.

  Returns `%{path => {:ok, size} | {:error, reason}}` for every distinct path
  in `paths`. Sizes only — nothing else in a batch's stat is read, and skipping
  `File.Stat` construction keeps the batched parse trivial. A path the batch
  did not report is re-statted with `stat/3`, so its reason and operator log
  line are exactly what a per-path `stat/3` would produce. See
  `Nest.Sandbox.StatBatch` for the framing and failure handling.
  """
  @spec stat_many([String.t()], map(), Mounts.t()) ::
          %{required(String.t()) => {:ok, non_neg_integer()} | {:error, atom() | term()}}
  def stat_many(paths, caps, mounts) do
    StatBatch.stat_many(paths, caps, mounts)
  end

  @doc """
  Expand a glob `pattern` (a sandbox-domain path) to readable regular
  files by running a bash glob loop inside the sandbox. Because the glob runs
  inside the sandbox, it sees exactly what the backend exposes — including
  the `/tmp` scratch bind and any project mounts — and returns the matches
  as `/tmp/<agent>/...` and the workspace's own paths, which is the only
  domain an agent names.

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one non-`/`
  char), and `**` (any run of path segments when it occupies a full
  segment). A pattern ending in a full-segment `**` is refused
  (`{:error, :glob_terminal_double_star}`): bash would eagerly expand the
  whole subtree, and the file-only filter would then apply recursively
  rather than to the matched directories.

  `opts` accepts `limit:` (default 1 000), the max number of raw matches the
  pattern may produce before the call returns `{:error, :glob_too_broad}` (so a
  scatter caller can ask the model to narrow the pattern rather than fork an
  unbounded set). A resolve failure for a relative pattern with no workspace
  returns `{:error, reason}`.

  Runs inside the sandbox; see `Nest.Sandbox.Glob`.
  """
  @spec glob(String.t(), map(), Mounts.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, atom() | term()}
  def glob(pattern, caps, mounts, opts \\ [])
      when is_binary(pattern) and is_map(caps) do
    Glob.run(pattern, caps, mounts, opts)
  end

  @doc """
  Run `command` inside the sandbox. Authorizes nothing further
  itself — the mounts enforce filesystem rules. Delegates to
  `ShellCmd.execute/4`.
  """
  @spec run(String.t(), Mounts.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(command, mounts, caps, opts \\ []) do
    ShellCmd.execute(command, mounts, caps, opts)
  end

  @doc """
  Write `content` to `path` inside the sandbox. Write
  permissions are enforced by the bind mounts, so a write outside the
  permitted paths fails at the kernel level (read-only file system)
  rather than being pre-authorized here. Returns `{:ok, output}` or
  `{:error, reason}`.
  """
  @spec write(String.t(), binary(), map(), Mounts.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def write(path, content, caps, mounts) do
    ShellCmd.execute(
      "cat > #{ShellEscape.escape(path)}",
      mounts,
      caps,
      stdin: content
    )
  end

  @doc """
  Write `content` to `name` in the agent's scratch directory and return the
  agent-visible `/tmp/<agent-name>/<name>` spelling, or `nil` when there is no
  scratch directory or the write fails.

  This is the sandbox's own bookkeeping rather than the agent-facing `write/4`:
  its one caller is `Nest.Agents.Agent.BatchSizer.Overflow`, which offloads a
  result too large to inline, and all the caller keeps is the path it returns.

  A backend whose scratch directory is a host directory takes the bytes
  directly, which keeps an offload off the sandbox's hot path. Under `"docker"`
  the scratch is the container's own `/tmp`, which only the container can write,
  so the bytes go through the gatekeeper instead — one `docker exec` per
  offload, which is rare enough to be worth it.
  """
  @spec scratch_write(Mounts.t(), String.t(), binary()) :: String.t() | nil
  def scratch_write(mounts, name, content) do
    case Mounts.scratch(mounts) do
      nil ->
        nil

      dir ->
        if write_scratch_file(mounts, Path.join(dir, name), content) do
          Path.join(Paths.sandbox_tmp_path(dir), name)
        end
    end
  end

  defp write_scratch_file(%Mounts{} = mounts, path, content) do
    if Mounts.host_scratch?(mounts) do
      try do
        File.write!(path, content)
        true
      rescue
        _ -> false
      end
    else
      command = "cat > " <> ShellEscape.escape(path)

      match?({:ok, _output}, ShellCmd.execute(command, mounts, nil, stdin: content))
    end
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
      0x6000 -> :device
      _ -> :other
    end
  end

  # ---- workspace policy ----

  @doc """
  Validate an agent workspace path.

  Returns `:ok`, `{:error, :workspace_missing}` (the path is not an existing
  directory), or `{:error, :workspace_under_tmp}` (the path is at or under
  `#{Paths.sandbox_root()}`, which the scratch bind shadows). `nil` means "no
  workspace" and is always `:ok`; whether a workspace is *required* is the
  caller's policy (see `Nest.Vocations.requires_workspace?/1`).
  """
  @spec workspace_error(String.t() | nil) ::
          :ok | {:error, :workspace_missing | :workspace_under_tmp}
  def workspace_error(nil), do: :ok

  def workspace_error(workspace) when is_binary(workspace) do
    cond do
      FSPath.under?(Paths.sandbox_root(), FSPath.canonical(workspace)) ->
        {:error, :workspace_under_tmp}

      not File.dir?(workspace) ->
        {:error, :workspace_missing}

      true ->
        :ok
    end
  end

  # The final gate for anything that reaches the sandbox. A workspace at or
  # under the scratch bind's mount point (`/tmp`) would be shadowed, and a
  # non-existent workspace cannot be bound, so both are rejected here
  # unconditionally.
  defp validate_workspace(workspace) do
    case workspace_error(workspace) do
      :ok ->
        :ok

      {:error, :workspace_under_tmp} ->
        {:error,
         "workspace must not be at or under #{Paths.sandbox_root()}: " <>
           "the sandbox scratch dir is bound there and would shadow it"}

      {:error, :workspace_missing} ->
        {:error, "Workspace directory does not exist: #{workspace}"}
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

  # Every bind this call makes, rendered as bwrap's own flags. The set itself is
  # `Nest.Sandbox.Binds`'s — the docker backend renders the same triples over the
  # container's root, which is what keeps the two backends binding the same
  # things.
  defp append_binds(args, caps, mounts) do
    binds =
      caps
      |> Binds.specs(mounts)
      |> Enum.flat_map(fn {source, dest, mode} -> [bind_flag(mode), source, dest] end)

    args ++ binds
  end

  defp bind_flag(:rw), do: "--bind"
  defp bind_flag(:ro), do: "--ro-bind"

  # `nil` chdir means "no workspace": land in the scratch root when one is
  # bound (the effective cwd before the workspace was made explicit), else
  # the read-only root.
  defp append_chdir(args, nil, %Mounts{scratch: nil}), do: args ++ ["--chdir", "/"]

  defp append_chdir(args, nil, %Mounts{scratch: _scratch}),
    do: args ++ ["--chdir", Paths.sandbox_root()]

  defp append_chdir(args, chdir_path, _mounts), do: args ++ ["--chdir", chdir_path]

  defp read_list(caps), do: get_in(caps, ["fs", "read"]) || []
end
