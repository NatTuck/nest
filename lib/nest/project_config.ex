defmodule Nest.ProjectConfig do
  @moduledoc """
  Per-project sandbox configuration loaded from `<project>/.nest`.

  A project may drop a `.nest` file in its root to grant the sandbox
  extra filesystem access it needs to build/test. The file is TOML:

      [[mount]]
      path   = "~/.local/data/inkfish/uploads/test"
      mode   = "rw" # "rw" | "tmp"
      create = true      # default false

      [shell]
      background = 3     # max concurrent background shell jobs per agent

  Each `[[mount]]` entry declares a `path` (absolute, `~`-expanded, or
  relative to the project root) and a `mode`:

    * `"rw"` — bind the host path read-write at its own path.
    * `"tmp"` — bind a directory under the agent's scratch dir (the
      agent's own sub-directory of the space scratch dir) at `path`.
      On a `bwrap` space the backing directory is a host directory, so
      writes never touch the project; the directory persists for the
      agent's lifetime (and is visible inside the sandbox under
      `/tmp/<agent-name>/project/<slug>`). A `docker` space's scratch is
      the container's own `/tmp`, so there is no host directory to back
      this with and the mount is **refused by name** — use `"rw"` there.

  `create = true` makes Nest `mkdir_p` the path before mounting, so a
  project can declare a scratch path whose parents don't exist yet.

  The optional `[shell]` table raises the per-agent ceiling on
  concurrent background shell jobs (`shell-cmd` with `background: true`;
  see `Nest.Sandbox.ShellJobs`). It defaults to 1, and 0 disables
  background jobs. Unlike mounts, the `[shell]` cap is **not** gated on
  a writable workspace: it is not a filesystem grant, so it applies in
  every mode.

  The optional `[sandbox]` table declares Debian packages to add to a
  `"docker"` space's image:

      [sandbox]
      packages = ["nodejs", "elixir"]

  Names must look like Debian package names (`^[a-z0-9][a-z0-9+.-]*$`); the
  list is additive and only affects the docker backend's derived image
  (`Nest.Sandbox.Backend.Docker`). Like `[shell]`, it is not a filesystem
  grant, so it applies in every mode — the toolchain is in the container,
  not on the host.

  ## Gating

  Project mounts are merged into a mode's caps **only when that mode
  already writes the symbolic `":workspace"`** — a read-only mode must
  stay read-only. In those modes the two human-authored config files are
  mounted read-only (see `Nest.Sandbox`), so an agent can never edit its own
  sandbox or its own instructions: `.nest`, which grants host access, and
  `AGENTS.md`, which is the project's policy rendered into its prompt. When
  either is absent, a read-only `/dev/null` is masked over the path so an
  agent can't create one either.

  The two are one class and get one treatment. Both are read on the **host** by
  the runtime — `load/1` for `.nest`, `Nest.Agents.Agent.SystemPrompt` for
  `AGENTS.md` — and handed to the sandbox as read-only binds rather than
  discovered by it, so **a regular file at either path** is the host's file by
  construction, on every backend. A path that is *not* a regular file (a symlink,
  a directory) cannot be masked at all, so it is **refused** rather than
  tolerated — `Nest.ConfigFile.error/1`, reached from
  `Nest.Sandbox.workspace_error/1`, is the gate.

  Both halves of that are **binds**, so they hold only on a backend that
  binds: a `"none"` space has no sandbox to protect, and an agent there can
  edit or create its own `.nest` or `AGENTS.md` like any other file. That is the
  same statement as "caps cannot be enforced for a `"none"` space" (see
  `Nest.Sandbox.Backend.None`), not a separate hole.

  The *refusal* of a config path that is not a regular file
  (`Nest.ConfigFile.error/1`) is **unconditional on every backend**, `"none"`
  included. It is a property of the workspace rather than of the backend, so it
  answers the same question everywhere and cannot be sidestepped by changing the
  answer where enforcement is weaker. The cost is a `"none"` space being refused
  for a protection that backend could not have offered anyway, and the remedy is
  the same everywhere: copy the file into the workspace instead of linking it.
  The alternative is a gate that means something different on each backend.

  ## Failures

  A malformed `.nest` never degrades silently: `load/1` logs an error,
  `resolve_caps/2` leaves the mode's caps unchanged, and
  `section/1` renders a visible error block into the system prompt.
  """

  require Logger

  alias Nest.FSPath
  alias Nest.ParseCache
  alias Nest.Sandbox.Mounts

  @modes ~w(rw tmp)

  @typedoc "A project mount with its host path expanded."
  @type mount :: map()

  @typedoc "The `[shell]` sandbox settings from `.nest`."
  @type shell :: %{optional(String.t()) => non_neg_integer()}

  @typedoc "The `[sandbox]` settings from `.nest`."
  @type sandbox :: %{optional(String.t()) => [String.t()]}

  @typedoc "The parsed `.nest` file: mounts plus optional `[shell]` and `[sandbox]` settings."
  @type config :: %{optional(String.t()) => [mount()] | shell() | sandbox() | nil}

  @doc """
  Load and parse `<workspace>/.nest`.

  The file is read on every call, because that read is how a change is noticed;
  only the parse and validate step is cached, keyed on the bytes that were read
  (`Nest.ParseCache`). A rewritten `.nest` is therefore picked up on its own —
  new bytes are a new key, whatever the file's mtime happens to be — and no
  caller has to clear anything first.

  Returns `{:ok, config}` (`%{"mounts" => []}` when there is no file)
  or `{:error, reason}` when the file exists but is malformed.
  """
  @spec load(String.t() | nil) :: {:ok, config()} | {:error, String.t()}
  def load(workspace) when is_binary(workspace) do
    path = Path.join(workspace, Nest.ConfigFile.nest_name())

    case Nest.ConfigFile.read(path) do
      {:ok, content} ->
        parse_cached(path, content, workspace)

      :absent ->
        {:ok, %{"mounts" => []}}

      # Reached when a config path is replaced *while an agent is running*:
      # composition is re-run on compaction, so this is not the start gate's
      # business. A `.nest` we cannot protect must not degrade silently — the same
      # rule a malformed one follows — so this is an error, which `section/1`
      # renders as a visible block.
      # `error_message/1` rather than a sentence of its own: a hardlink **is** a
      # regular file, so the type has to reach the wording, and this is the
      # mid-session re-render path the model reads.
      {:not_regular, type} ->
        {:error, Nest.ConfigFile.error_message({:config_file_not_regular, path, type})}

      {:error, reason} ->
        read_failure(path, reason)
    end
  end

  def load(nil), do: {:ok, %{"mounts" => []}}

  # The read succeeded, so the bytes are the cache key. A failure is cached
  # beside a success: a malformed file is remembered as malformed for exactly
  # those bytes, which is what keeps its error logged once per revision instead
  # of once per load.
  defp parse_cached(path, content, workspace) do
    case ParseCache.fetch(path, content) do
      {:ok, result} ->
        result

      :miss ->
        result = parse(content, workspace)
        ParseCache.put(path, content, result)
        log_failure(path, result)
        result
    end
  end

  defp parse(content, workspace) do
    case Toml.decode(content) do
      {:ok, raw} -> validate(raw, workspace)
      {:error, reason} -> {:error, "invalid TOML: #{inspect(reason)}"}
    end
  end

  # An unreadable `.nest` has no bytes to key on, so this failure cannot be
  # memoized and is reported on every load.
  defp read_failure(path, reason) do
    result = {:error, "could not read .nest: #{inspect(reason)}"}
    log_failure(path, result)
    result
  end

  defp log_failure(path, {:error, reason}) do
    Logger.error("Nest.ProjectConfig: ignoring #{path}: #{reason}")
  end

  defp log_failure(_path, _result), do: :ok

  defp validate(raw, workspace) do
    with {:ok, mounts} <- validate_mounts(Map.get(raw, "mount", []), workspace),
         :ok <- reject_duplicates(mounts),
         {:ok, shell} <- validate_shell(Map.get(raw, "shell")),
         {:ok, sandbox} <- validate_sandbox(Map.get(raw, "sandbox")) do
      config = %{"mounts" => mounts}

      {:ok, if(shell, do: Map.put(config, "shell", shell), else: config)}
      |> put_sandbox(sandbox)
    end
  end

  defp put_sandbox({:ok, config}, nil), do: {:ok, config}
  defp put_sandbox({:ok, config}, sandbox), do: {:ok, Map.put(config, "sandbox", sandbox)}
  defp put_sandbox(error, _sandbox), do: error

  defp validate_sandbox(nil), do: {:ok, nil}

  defp validate_sandbox(raw) when is_map(raw) do
    case Map.get(raw, "packages", []) do
      packages when is_list(packages) ->
        if Enum.all?(packages, &valid_package?/1) do
          {:ok, %{"packages" => Enum.uniq(packages)}}
        else
          {:error, "sandbox packages must be Debian package names"}
        end

      _other ->
        {:error, "sandbox packages must be a list"}
    end
  end

  defp validate_sandbox(_raw), do: {:error, "sandbox must be a table"}

  # Debian package names: lower-case, digits, and `+`, `.` or `-` after the
  # first character. Refusing anything else keeps a malformed name from reaching
  # an `apt-get install` line.
  defp valid_package?(name) do
    is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9+.-]*\z/, name)
  end

  defp validate_shell(nil), do: {:ok, nil}

  defp validate_shell(raw) when is_map(raw) do
    case Map.get(raw, "background", 1) do
      n when is_integer(n) and n >= 0 -> {:ok, %{"background" => n}}
      _ -> {:error, "shell background must be a non-negative integer"}
    end
  end

  defp validate_shell(_raw), do: {:error, "shell must be a table"}

  defp validate_mounts(mounts, workspace) when is_list(mounts) do
    ws = FSPath.canonical(workspace)

    mounts
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case validate_mount(entry, ws) do
        {:ok, mount} -> {:cont, {:ok, [mount | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp validate_mounts(_mounts, _workspace), do: {:error, "mount must be an array of tables"}

  defp validate_mount(entry, ws) when is_map(entry) do
    with {:ok, raw_path} <- fetch_string(entry, "path"),
         {:ok, mode} <- fetch_mode(entry),
         {:ok, create} <- fetch_create(entry),
         {:ok, dest} <- expand_dest(raw_path, ws) do
      {:ok, %{"dest" => dest, "mode" => mode, "create" => create}}
    end
  end

  defp validate_mount(_entry, _ws), do: {:error, "each [[mount]] must be a table"}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "mount #{key} must be a non-empty string"}
    end
  end

  defp fetch_mode(map) do
    case Map.get(map, "mode") do
      mode when mode in @modes -> {:ok, mode}
      _ -> {:error, "mount mode must be one of: rw, tmp"}
    end
  end

  defp fetch_create(map) do
    case Map.get(map, "create", false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "mount create must be a boolean"}
    end
  end

  # Expand a mount path (`~`-aware, relative to the project root),
  # resolve symlinks. The filesystem root is rejected: binding it read-write would defeat the sandbox.
  defp expand_dest(raw, ws) do
    dest = raw |> Path.expand(ws) |> FSPath.canonical()

    if dest == "/" do
      {:error, "mount path must not be /"}
    else
      {:ok, dest}
    end
  end

  defp reject_duplicates(mounts) do
    dests = Enum.map(mounts, & &1["dest"])

    if length(dests) == length(Enum.uniq(dests)) do
      :ok
    else
      {:error, "duplicate mount paths"}
    end
  end

  @doc """
  Merge the project config into `caps`, returning effective caps.

  Only modes that write the symbolic `":workspace"` receive project
  mounts (plus the read-only mask over `.nest` and `AGENTS.md`); every other mode
  is returned unchanged. Returns `{:error, reason}` when `.nest` is
  malformed.
  """
  @spec effective_caps(map(), Mounts.t()) :: {:ok, map()} | {:error, String.t()}
  def effective_caps(caps, mounts) do
    with {:ok, config} <- load(Mounts.workspace(mounts)) do
      {:ok, merge(caps, config, mounts)}
    end
  end

  @doc """
  Resolve the caps a *call* runs under, from the caps a *mode* gives.

  This is where a mode's caps become a call's caps, and the name says so: the
  space's network access is injected first, then the project's `.nest` is merged
  on top. Never fails — a malformed `.nest` leaves `caps` unchanged (the mode's
  default sandbox is in effect) and `load/1` logs the error.

  It is the one funnel both caps-resolution paths share
  (`Nest.Agents.Agent.resolve_caps/1` and
  `Nest.Agents.Agent.ChatPipeline.resolve_mode_and_caps/3`), which is why the
  space's `net` goes in here rather than in either of them.
  """
  @spec resolve_caps(map(), Mounts.t()) :: map()
  def resolve_caps(caps, mounts) do
    # The space's network access goes in *here*, before the project config, so
    # that a malformed `.nest` cannot drop it and so that both caps-resolution
    # paths (`Nest.Agents.Agent.resolve_caps/1` and
    # `Nest.Agents.Agent.ChatPipeline.resolve_mode_and_caps/3`) inject it by
    # calling this one function — it is not a project setting, but this is the
    # one place a mode's caps become the caps for a call.
    caps = Nest.Sandbox.with_network_access(caps, mounts)

    case effective_caps(caps, mounts) do
      {:ok, merged} -> merged
      {:error, _reason} -> caps
    end
  end

  # The `[shell]` background cap and the `[sandbox]` packages apply in every
  # mode: neither is a filesystem grant (one is a job ceiling, the other is
  # tooling inside the container), so a read-only mode gets both.
  defp merge(caps, config, mounts) do
    caps
    |> put_shell(config)
    |> put_sandbox_packages(config)
    |> maybe_put_project_mounts(mounts, config)
  end

  # Project mounts are additive write capabilities, so they only make
  # sense in modes that can already write the project. Other modes are
  # returned untouched (a read-only mode must stay read-only).
  defp maybe_put_project_mounts(caps, mounts, config) do
    workspace = Mounts.workspace(mounts)

    if is_binary(workspace) and workspace_writable?(caps) do
      caps
      |> put_in(["fs", "project"], resolve_mounts(mounts(config), Mounts.scratch(mounts)))
      |> put_in(["fs", "protected"], protected_entries(workspace))
    else
      caps
    end
  end

  # The `[shell]` cap is an additive grant (raising the per-agent
  # background-job ceiling).
  defp put_shell(caps, %{"shell" => %{"background" => n}}) do
    shell = caps |> Map.get("shell", %{}) |> Map.put("background", n)
    Map.put(caps, "shell", shell)
  end

  defp put_shell(caps, _config), do: caps

  # The declared package set, carried in caps so the docker backend reads it
  # from the value it already has instead of re-reading `.nest` on every command.
  defp put_sandbox_packages(caps, %{"sandbox" => %{"packages" => packages}}) do
    sandbox = caps |> Map.get("sandbox", %{}) |> Map.put("packages", packages)
    Map.put(caps, "sandbox", sandbox)
  end

  defp put_sandbox_packages(caps, _config), do: caps

  defp mounts(%{"mounts" => mounts}), do: mounts
  defp mounts(_config), do: []

  defp shell(%{"shell" => shell}), do: shell
  defp shell(_config), do: nil

  @doc """
  The Debian packages a project's `.nest` adds to a `"docker"` space's image.

  Reads them from `caps` (where `effective_caps/2` put them) so a caller needs
  no `.nest` read of its own, and returns `[]` for a mode whose `.nest` declares
  none.
  """
  @spec sandbox_packages(map() | nil) :: [String.t()]
  def sandbox_packages(caps), do: get_in(caps, ["sandbox", "packages"]) || []

  defp workspace_writable?(caps), do: ":workspace" in (get_in(caps, ["fs", "write"]) || [])

  defp resolve_mounts(mounts, tmp_path) do
    Enum.map(mounts, fn mount -> Map.put(mount, "source", source_for(mount, tmp_path)) end)
  end

  defp source_for(%{"mode" => "rw", "dest" => dest}, _tmp_path), do: dest

  defp source_for(%{"mode" => "tmp", "dest" => dest}, tmp_path) when is_binary(tmp_path) do
    Path.join([tmp_path, "project", slug(dest)])
  end

  defp source_for(_mount, _tmp_path), do: nil

  defp slug(dest) do
    :crypto.hash(:sha256, dest) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # The `.nest` and `AGENTS.md` files are always protected (read-only) in a
  # writable workspace. Both are **human-authored project config**: `.nest`
  # grants host access, `AGENTS.md` states the project's policy, and an agent
  # that can rewrite either drifts its own constraints — which is why the
  # runtime reads them on the host (`Nest.ProjectConfig.load/1` for one,
  # `Nest.Agents.Agent.SystemPrompt` for the other) and the sandbox is *handed*
  # them as read-only binds rather than discovering them.
  #
  # When a file is absent we mask `/dev/null` over its path so an agent can't
  # create one (which would be picked up on the next spawn and grant it extra
  # host access, or quietly change its own prompt). The mask is a real bind
  # inside the sandbox, so `stat`/`read` see the char device directly — and,
  # because bwrap's `--ro-bind` mounts with `nodev`, *reading* it fails with
  # `EACCES` rather than returning empty bytes. That is what both binding
  # backends do, identically. A backend that binds nothing has nothing to mask
  # with (see the moduledoc's Gating section).
  defp protected_entries(workspace) do
    ws = canonical_ws(workspace)
    names = [Nest.ConfigFile.nest_name(), Nest.ConfigFile.agents_md_name()]
    Enum.flat_map(names, &protected_entry(Path.join(ws, &1)))
  end

  # A regular file is masked over itself; an absent one is masked with
  # `/dev/null` so it cannot be created. A path that exists but is not a regular
  # file gets **no entry** — and that is defensive only, because omitting the
  # entry is *not* protection: with no mount point over the path an `act` agent
  # could delete the symlink and write a regular `.nest` that grants host access.
  # The mechanism is the gate, `Nest.ConfigFile.error/1`, which refuses the workspace
  # before any of this runs.
  defp protected_entry(path) do
    case Nest.ConfigFile.state(path) do
      :regular -> [%{"path" => path, "source" => path}]
      :absent -> [%{"path" => path, "source" => "/dev/null"}]
      {:not_regular, _type} -> []
    end
  end

  # The canonical-workspace memo's table. (The `.nest` parse has its own cache,
  # keyed on the file's bytes, in `Nest.ParseCache`.)
  @cache_table :nest_project_config_cache

  defp cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @cache_table
        end

      _ ->
        @cache_table
    end
  end

  @doc """
  Create the canonical-workspace memo's table, if it is not there already.

  Called from `Nest.Application.start/2` so the table is owned by the application
  rather than by whichever process needed it first. It used to be created lazily
  by the first reader — usually an agent composing a prompt — so stopping that
  agent deleted the table and a concurrent reader crashed on `:ets.lookup` with
  "the table identifier does not refer to an existing ETS table". `cache_table/0`
  keeps its lazy fallback for a caller outside a running application.
  """
  @spec init_cache() :: :ok
  def init_cache do
    _ = cache_table()
    :ok
  end

  # `FSPath.canonical/1` shells out to `realpath`; cache the result per
  # workspace so per-message caps resolution doesn't spawn a process.
  defp canonical_ws(workspace) do
    key = {:workspace, workspace}

    case :ets.lookup(cache_table(), key) do
      [{_, canonical}] ->
        canonical

      [] ->
        canonical = FSPath.canonical(workspace)
        :ets.insert(cache_table(), {key, canonical})
        canonical
    end
  end

  @doc """
  `mkdir_p` project-mount backing dirs before the sandbox starts: `tmp` sources
  must exist to be bind sources, and `create = true` dirs must exist to
  be mount points.
  """
  @spec ensure_dirs(map()) :: :ok
  def ensure_dirs(caps) do
    Enum.each(project_mounts(caps), fn
      %{"mode" => "tmp", "source" => source} when is_binary(source) ->
        File.mkdir_p!(source)

      %{"mode" => "rw", "create" => true, "dest" => dest} ->
        File.mkdir_p!(dest)

      _ ->
        :ok
    end)
  end

  defp project_mounts(caps), do: get_in(caps, ["fs", "project"]) || []

  @doc """
  The system-prompt section describing the project sandbox config, or a
  visible error block when `.nest` is malformed. Returns an empty
  string when there is no `.nest` (or no workspace).
  """
  @spec section(String.t() | nil) :: String.t()
  def section(workspace) do
    case load(workspace) do
      {:ok, config} -> if empty_config?(config), do: "", else: render_section(config)
      {:error, reason} -> error_section(reason)
    end
  end

  defp empty_config?(config) do
    mounts(config) == [] and shell(config) == nil and sandbox_packages_config(config) == []
  end

  defp render_section(config) do
    lines =
      Enum.map(mounts(config), &render_mount/1) ++
        shell_lines(config) ++ package_lines(config)

    "\n\n[Project sandbox config]\n\n" <>
      "This project has a `.nest` file granting extra sandbox settings " <>
      "(only in modes that can write the project):\n\n" <>
      Enum.join(lines, "\n") <>
      "\n\nThe `.nest` file itself is mounted read-only, like `AGENTS.md`.\n"
  end

  defp shell_lines(%{"shell" => %{"background" => n}}) do
    ["- at most #{n} background shell job(s) per agent"]
  end

  defp shell_lines(_config), do: []

  # The packages are in the docker image, not on the host, so the line says
  # where they are — an agent that reaches for `node` on a bwrap space would
  # otherwise read this as a promise about its own environment.
  defp package_lines(config) do
    case sandbox_packages_config(config) do
      [] ->
        []

      packages ->
        ["- a docker sandbox image with these packages: #{Enum.join(packages, ", ")}"]
    end
  end

  defp sandbox_packages_config(%{"sandbox" => %{"packages" => packages}}), do: packages
  defp sandbox_packages_config(_config), do: []

  defp render_mount(%{"dest" => dest, "mode" => "rw"}),
    do: "- read-write access to #{dest}"

  defp render_mount(%{"dest" => dest, "mode" => "tmp"}),
    do: "- #{dest} backed by a scratch directory under the agent /tmp"

  defp error_section(reason) do
    "\n\n[Project sandbox config error]\n\n" <>
      ".nest could not be loaded: #{reason}. " <>
      "No project mounts were applied; the mode's default sandbox is in effect.\n"
  end
end
